defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}

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

  @label_context_query """
  query SymphonyIssueLabelContext($issueId: String!, $labelName: String!) {
    issue(id: $issueId) {
      labels {
        nodes { id }
      }
      team {
        labels(filter: {name: {eq: $labelName}}, first: 1) {
          nodes { id }
        }
      }
    }
  }
  """

  @update_labels_mutation """
  mutation SymphonyUpdateIssueLabels($issueId: String!, $labelIds: [String!]!) {
    issueUpdate(id: $issueId, input: {labelIds: $labelIds}) {
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

  @spec fetch_issues_with_labels([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_with_labels(label_names), do: client_module().fetch_issues_with_labels(label_names)

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

  @spec add_label(term(), String.t()) :: :ok | {:error, term()}
  def add_label(%Issue{id: issue_id}, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, {current_ids, target_id}} <- fetch_label_context(issue_id, label_name) do
      do_add_label(issue_id, label_name, current_ids, target_id)
    end
  end

  @spec remove_label(term(), String.t()) :: :ok | {:error, term()}
  def remove_label(%Issue{id: issue_id}, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, {current_ids, target_id}} <- fetch_label_context(issue_id, label_name) do
      do_remove_label(issue_id, current_ids, target_id)
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp do_add_label(_issue_id, label_name, _current_ids, nil), do: {:error, {:label_not_found, label_name}}

  defp do_add_label(issue_id, _label_name, current_ids, target_id) do
    if Enum.member?(current_ids, target_id) do
      :ok
    else
      update_label_ids(issue_id, [target_id | current_ids])
    end
  end

  defp do_remove_label(_issue_id, _current_ids, nil), do: :ok

  defp do_remove_label(issue_id, current_ids, target_id) do
    if Enum.member?(current_ids, target_id) do
      update_label_ids(issue_id, Enum.reject(current_ids, &(&1 == target_id)))
    else
      :ok
    end
  end

  defp update_label_ids(issue_id, label_ids) do
    with {:ok, response} <-
           client_module().graphql(@update_labels_mutation, %{issueId: issue_id, labelIds: label_ids}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp fetch_label_context(issue_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@label_context_query, %{issueId: issue_id, labelName: label_name}),
         issue_data when is_map(issue_data) <- get_in(response, ["data", "issue"]) do
      current_label_ids =
        issue_data
        |> get_in(["labels", "nodes"])
        |> List.wrap()
        |> Enum.map(& &1["id"])
        |> Enum.reject(&is_nil/1)

      target_label_id = get_in(issue_data, ["team", "labels", "nodes", Access.at(0), "id"])

      {:ok, {current_label_ids, target_label_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_context_fetch_failed}
    end
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
end
