defmodule ReceptionDesk.Application do
  use Application
  def start(_type, _args) do
    Supervisor.start_link([
      %{id: :ba_reception_sessions, start: {:ba_reception_sessions, :start_link, []}},
      {Phoenix.PubSub, name: ReceptionDesk.PubSub}, ReceptionDesk.Endpoint
    ], strategy: :rest_for_one, name: ReceptionDesk.Supervisor)
  end
end

defmodule ReceptionDesk.Errors do
  def render(_template, _assigns), do: %{error: "Request failed"}
end

defmodule ReceptionDesk.Router do
  use Plug.Router
  plug :match
  plug :dispatch

  get "/relay/v1" do
    conn
    |> WebSockAdapter.upgrade(ReceptionDesk.Socket, %{}, timeout: 45_000, max_frame_size: 131_072)
    |> halt()
  end
  get "/health" do
    send_resp(put_resp_content_type(conn, "application/json"), 200,
      Jason.encode!(%{service: "ReceptionDesk", protocol: 1}))
  end
  get "/" do
    html = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>BEAM Audio Reception</title><body style="font:18px system-ui;max-width:44rem;margin:4rem auto;padding:1rem">
    <h1>BEAM Audio Reception</h1><p>Reception authenticates Devices, introduces them and routes messages over their open WebSocket connections.</p>
    <p>In your app, set Reception’s WebSocket address (this origin with <code>/relay/v1</code>),
    create a Buffee and share its invitation. Choose <strong>Join a Buffee</strong> in OpenSound and paste an invitation to join.</p>
    <p>Your Device controls its participation, audio and computing capacity. Reception introduces Devices; it does not carry audio or control their resources.</p></body></html>
    """
    conn |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/html") |> send_resp(200, html)
  end
  match _, do: send_resp(conn, 404, "Not found")
end

defmodule ReceptionDesk.Socket do
  @behaviour WebSock
  def init(_) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(32))
    Process.send_after(self(), :auth_timeout, 10_000)
    Process.send_after(self(), :ping, 15_000)
    push(%{op: "challenge", v: 1, nonce: nonce},
      %{id: nil, nonce: nonce, window: System.monotonic_time(:second), count: 0, bytes: 0})
  end
  def handle_in({data, [opcode: :text]}, state) when byte_size(data) <= 131_072 do
    now = System.monotonic_time(:second)
    state = if state.window == now, do: %{state | count: state.count + 1, bytes: state.bytes + byte_size(data)},
      else: %{state | window: now, count: 1, bytes: byte_size(data)}
    if state.count > 512 or state.bytes > 8_388_608 do
      {:stop, :normal, {1008, "Rate limit"}, state}
    else
      try do
        command(Jason.decode!(data), state)
      rescue
        _ -> {:stop, :normal, {1008, "Invalid protocol message"}, state}
      end
    end
  end
  def handle_in({_data, [opcode: :pong]}, state), do: {:ok, state}
  def handle_in(_, state), do: {:stop, :normal, {1008, "Text messages required"}, state}
  def handle_info(:auth_timeout, %{id: nil} = state), do: {:stop, :normal, {1008, "Authentication timeout"}, state}
  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, 15_000)
    {:push, {:ping, ""}, state}
  end
  def handle_info(:replaced, state), do: {:stop, :normal, {1008, "Session replaced"}, state}
  def handle_info({:relay, message}, state), do: push(message, state)
  def handle_info(_, state), do: {:ok, state}
  def terminate(_, _), do: :ok

  defp command(%{"op" => "hello", "v" => 1, "id" => id, "signature" => signature}, %{id: nil} = state) do
    true = is_binary(id) and byte_size(id) == 64
    public = Base.decode16!(id, case: :upper)
    sig = Base.decode16!(signature, case: :upper)
    true = :crypto.verify(:eddsa, :none, "beamaudio-desk/v1:" <> state.nonce, sig, [public, :ed25519])
    :ok = :ba_reception_sessions.attach(id, self())
    push(%{op: "ready", v: 1, id: id}, %{state | id: id, nonce: nil})
  end
  defp command(message, %{id: id} = state) when is_binary(id) do
    result = :ba_reception_sessions.command(id, self(), message)
    case result do
      :ok -> {:ok, state}
      {:error, reason} -> push(%{op: "error", error: Atom.to_string(reason), request: message["request"]}, state)
    end
  end
  defp push(message, state), do: {:push, {:text, Jason.encode!(message)}, state}
end

defmodule ReceptionDesk.Endpoint do
  use Phoenix.Endpoint, otp_app: :reception_desk
  plug ReceptionDesk.Router
end

