defmodule SymphonyElixir.Workpad.LinearClient do
  @moduledoc """
  Default Linear-backed client for `SymphonyElixir.Workpad`.

  Implements the three operations the workpad module needs:

    * `list_comments/1`
    * `create_comment/2`
    * `update_comment/2`

  Shells to `SymphonyElixir.Linear.Client.graphql/3` so we inherit the existing
  auth, error-logging, and retry policy. This is intentionally separate from
  the `SymphonyElixir.Tracker` boundary, which is a `:ok | {:error, _}` shape
  inherited from upstream Symphony and is consumed by the existing in-memory
  tracker tests. Workpad needs comment ids back, which Tracker does not surface.
  """

  alias SymphonyElixir.Linear.Client

  @list_comments_query """
  query SymphonyWorkpadListComments($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      comments(first: $first) {
        nodes {
          id
          body
        }
      }
    }
  }
  """

  @create_comment_mutation """
  mutation SymphonyWorkpadCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyWorkpadUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment {
        id
      }
    }
  }
  """

  @page_size 100

  @spec list_comments(String.t()) ::
          {:ok, [%{id: String.t(), body: String.t()}]} | {:error, term()}
  def list_comments(issue_id) when is_binary(issue_id) do
    case Client.graphql(@list_comments_query, %{issueId: issue_id, first: @page_size}) do
      {:ok, %{"data" => %{"issue" => nil}}} ->
        {:error, :issue_not_found}

      {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => nodes}}}}}
      when is_list(nodes) ->
        comments =
          nodes
          |> Enum.map(fn node -> %{id: node["id"], body: node["body"] || ""} end)
          |> Enum.reject(fn comment -> is_nil(comment.id) end)

        {:ok, comments}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _other} ->
        {:error, :workpad_list_comments_unknown_payload}

      {:error, _} = err ->
        err
    end
  end

  @spec create_comment(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case Client.graphql(@create_comment_mutation, %{issueId: issue_id, body: body}) do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => id}}}}}
      when is_binary(id) ->
        {:ok, id}

      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}} ->
        {:error, :workpad_comment_id_missing}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _other} ->
        {:error, :workpad_comment_create_failed}

      {:error, _} = err ->
        err
    end
  end

  @spec update_comment(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    case Client.graphql(@update_comment_mutation, %{commentId: comment_id, body: body}) do
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => id}}}}}
      when is_binary(id) ->
        {:ok, id}

      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}} ->
        {:ok, comment_id}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _other} ->
        {:error, :workpad_comment_update_failed}

      {:error, _} = err ->
        err
    end
  end
end
