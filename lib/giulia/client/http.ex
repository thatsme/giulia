defmodule Giulia.Client.HTTP do
  @moduledoc """
  HTTP transport layer for the Giulia thin client.
  All daemon communication flows through get/1 and post/2.
  """

  @daemon_url "http://localhost:4000"

  def daemon_url, do: @daemon_url

  def get(path) do
    url = @daemon_url <> path

    case Req.get(url, decode_body: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  def post(path, body) do
    url = @daemon_url <> path

    # Long timeout for chat - orchestrator can take multiple iterations
    timeout = if String.contains?(path, "/command"), do: 300_000, else: 30_000

    case Req.post(url, json: body, decode_body: false, receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
