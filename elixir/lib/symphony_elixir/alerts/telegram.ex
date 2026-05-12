defmodule SymphonyElixir.Alerts.Telegram do
  @moduledoc false

  require Logger

  @type send_result :: {:ok, integer()} | {:noop, :unconfigured} | {:error, term()}

  @spec send(String.t()) :: send_result()
  def send(text) when is_binary(text) do
    case credentials() do
      {:ok, token, chat_id} -> do_send(token, chat_id, text)
      {:noop, reason} -> {:noop, reason}
    end
  end

  defp credentials do
    token = System.get_env("TELEGRAM_BOT_TOKEN")
    chat_id = System.get_env("TELEGRAM_CHAT_ID")

    cond do
      is_nil(token) or token == "" -> {:noop, :unconfigured}
      is_nil(chat_id) or chat_id == "" -> {:noop, :unconfigured}
      true -> {:ok, token, chat_id}
    end
  end

  defp do_send(token, chat_id, text) do
    case Application.get_env(:symphony_elixir, :telegram_send_fn) do
      fun when is_function(fun, 1) ->
        fun.(text)

      _ ->
        do_http_send(token, chat_id, text)
    end
  end

  defp do_http_send(token, chat_id, text) do
    url = "https://api.telegram.org/bot#{token}/sendMessage"
    body = %{"chat_id" => chat_id, "text" => text, "parse_mode" => "Markdown"}
    req_opts = Application.get_env(:symphony_elixir, :telegram_req_options, [])

    case Req.post(url, [json: body] ++ req_opts) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => id}}}} ->
        {:ok, id}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[Alerts.Telegram] API error status=#{status} body=#{inspect(resp_body)}")
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning("[Alerts.Telegram] HTTP error #{inspect(reason)}")
        {:error, reason}
    end
  end
end
