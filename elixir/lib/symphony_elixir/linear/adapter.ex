defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.

  Label mutations resolve names against the issue's team labels and cache the
  team label map in the process dictionary for the lifetime of the worker
  process. Missing labels return `{:error, :unknown_label}`.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @label_lookup_query """
  query SymphonyResolveLabelId($issueId: String!) {
    issue(id: $issueId) {
      team {
        id
        labels(first: 250) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """

  @add_label_mutation """
  mutation SymphonyAddIssueLabel($id: String!, $labelId: String!) {
    issueAddLabel(id: $id, labelId: $labelId) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyRemoveIssueLabel($id: String!, $labelId: String!) {
    issueRemoveLabel(id: $id, labelId: $labelId) {
      success
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label_name)
      when is_binary(issue_id) and is_binary(label_name) do
    update_issue_label(issue_id, label_name, @add_label_mutation, "issueAddLabel", :issue_add_label_failed)
  end

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label_name)
      when is_binary(issue_id) and is_binary(label_name) do
    update_issue_label(issue_id, label_name, @remove_label_mutation, "issueRemoveLabel", :issue_remove_label_failed)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp update_issue_label(issue_id, label_name, mutation, response_field, failure_reason) do
    with {:ok, label_id} <- resolve_label_id(issue_id, label_name),
         {:ok, response} <- client_module().graphql(mutation, %{id: issue_id, labelId: label_id}),
         true <- get_in(response, ["data", response_field, "success"]) == true do
      :ok
    else
      false -> {:error, failure_reason}
      {:error, reason} -> {:error, reason}
      _ -> {:error, failure_reason}
    end
  end

  defp resolve_label_id(issue_id, label_name) do
    case cached_label_id(issue_id, label_name) do
      {:ok, label_id} -> {:ok, label_id}
      :miss -> lookup_label_id(issue_id, label_name)
    end
  end

  defp cached_label_id(issue_id, label_name) do
    with team_id when is_binary(team_id) <-
           Map.get(Process.get({__MODULE__, :issue_team_cache}, %{}), issue_id),
         labels_by_name when is_map(labels_by_name) <-
           Map.get(Process.get({__MODULE__, :label_cache}, %{}), team_id),
         label_id when is_binary(label_id) <- Map.get(labels_by_name, label_name) do
      {:ok, label_id}
    else
      _ -> :miss
    end
  end

  defp lookup_label_id(issue_id, label_name) do
    with {:ok, response} <- client_module().graphql(@label_lookup_query, %{issueId: issue_id}),
         %{"id" => team_id, "labels" => %{"nodes" => nodes}}
         when is_binary(team_id) and is_list(nodes) <-
           get_in(response, ["data", "issue", "team"]) do
      labels_by_name = labels_by_name(nodes)
      cache_team_labels(issue_id, team_id, labels_by_name)

      case Map.fetch(labels_by_name, label_name) do
        {:ok, label_id} -> {:ok, label_id}
        :error -> {:error, :unknown_label}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_lookup_failed}
    end
  end

  defp labels_by_name(nodes) do
    Enum.reduce(nodes, %{}, fn
      %{"id" => id, "name" => name}, acc when is_binary(id) and is_binary(name) ->
        Map.put(acc, name, id)

      _node, acc ->
        acc
    end)
  end

  defp cache_team_labels(issue_id, team_id, labels_by_name) do
    label_cache =
      Process.get({__MODULE__, :label_cache}, %{})
      |> Map.put(team_id, labels_by_name)

    issue_team_cache =
      Process.get({__MODULE__, :issue_team_cache}, %{})
      |> Map.put(issue_id, team_id)

    Process.put({__MODULE__, :label_cache}, label_cache)
    Process.put({__MODULE__, :issue_team_cache}, issue_team_cache)
  end
end
