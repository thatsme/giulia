defmodule Giulia.Client.Approval do
  @moduledoc """
  User approval prompts for tool execution gates.
  """

  alias Giulia.Client.HTTP

  @spec prompt() :: boolean()
  def prompt do
    response = IO.gets("\e[1;33mApprove? [y/N]\e[0m ") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end

  @spec send_response(String.t(), boolean()) :: :ok
  def send_response(approval_id, approved) do
    # URL-encode the approval_id since it contains special chars (#, <, >, .)
    encoded_id = URI.encode(approval_id, &URI.char_unreserved?/1)
    url = HTTP.daemon_url() <> "/api/approval/#{encoded_id}"

    case Req.post(url, json: %{approved: approved}, decode_body: false, receive_timeout: 5000) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        IO.puts("\e[31mWarning: Failed to send approval (#{status}): #{body}\e[0m")

      {:error, reason} ->
        IO.puts("\e[31mWarning: Failed to send approval: #{inspect(reason)}\e[0m")
    end
  end
end
