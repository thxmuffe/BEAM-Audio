defmodule ReceptionDesk.RelayTest do
  use ExUnit.Case, async: false
  test "a claimed node ID without its private key cannot authenticate" do
    port = :ranch.get_port(ReceptionDesk.Endpoint.HTTP)
    {:ok, conn} = :gun.open(~c"127.0.0.1", port, %{protocols: [:http]})
    try do
      {:ok, :http} = :gun.await_up(conn)
      stream = :gun.ws_upgrade(conn, ~c"/relay/v1")
      assert_receive {:gun_upgrade, ^conn, ^stream, ["websocket"], _}, 2000
      assert_receive {:gun_ws, ^conn, ^stream, {:text, challenge}}, 2000
      assert %{"op" => "challenge", "nonce" => nonce} = Jason.decode!(challenge)
      assert byte_size(nonce) == 64
      {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
      :gun.ws_send(conn, stream, {:text, Jason.encode!(%{op: "hello", v: 1,
        id: Base.encode16(public), signature: String.duplicate("0", 128)})})
      assert_receive {:gun_ws, ^conn, ^stream, {:close, 1008, _}}, 2000
    after
      :gun.close(conn)
    end
  end
  test "mailboxes bind authenticated sender, recipient and swarm; no offline queue" do
    owner = Base.encode16(:crypto.strong_rand_bytes(32))
    sender = Base.encode16(:crypto.strong_rand_bytes(32))
    cap = Base.encode16(:crypto.strong_rand_bytes(16))
    swarm = Base.encode16(:crypto.strong_rand_bytes(16))
    :ok = :ba_reception_sessions.attach(owner, self())
    :ok = :ba_reception_sessions.attach(sender, self())
    assert :ok = :ba_reception_sessions.command(owner, self(), %{"op" => "open", "mailbox" => cap, "swarm" => swarm})
    envelope = %{"op" => "send", "to" => owner, "mailbox" => cap, "payload" => %{"swarm" => swarm, "from" => "forged"}}
    assert :ok = :ba_reception_sessions.command(sender, self(), envelope)
    assert_receive {:relay, %{op: "delivery", from: ^sender, mailbox: ^cap}}
    assert {:error, :unavailable} = :ba_reception_sessions.command(sender, self(), %{envelope | "mailbox" => "wrong"})
    assert {:error, :unavailable} = :ba_reception_sessions.command(sender, self(), %{envelope | "payload" => %{"swarm" => "wrong"}})
    other = spawn(fn -> receive do :stop -> :ok end end)
    assert {:error, :unauthenticated} = :ba_reception_sessions.command(sender, other, envelope)
    send(other, :stop)
    assert :ok = :ba_reception_sessions.command(owner, self(), %{"op" => "close", "mailbox" => cap})
    assert {:error, :unavailable} = :ba_reception_sessions.command(sender, self(), envelope)
  end

  test "capability lookup reports live owners without electing one" do
    cap = Base.encode16(:crypto.strong_rand_bytes(16))
    swarm = Base.encode16(:crypto.strong_rand_bytes(16))
    request = Base.encode16(:crypto.strong_rand_bytes(16))
    client = Base.encode16(:crypto.strong_rand_bytes(32))
    :ok = :ba_reception_sessions.attach(client, self())
    lookup = %{"op" => "lookup", "mailbox" => cap, "swarm" => swarm, "request" => request}
    assert :ok = :ba_reception_sessions.command(client, self(), lookup)
    assert_receive {:relay, %{op: "found", request: ^request, owners: []}}
    owners = for _ <- 1..2 do
      id = Base.encode16(:crypto.strong_rand_bytes(32))
      pid = spawn(fn -> receive do :stop -> :ok end end)
      :ok = :ba_reception_sessions.attach(id, pid)
      :ok = :ba_reception_sessions.command(id, pid, %{"op" => "open", "mailbox" => cap, "swarm" => swarm})
      {id, pid}
    end
    try do
      assert :ok = :ba_reception_sessions.command(client, self(), lookup)
      assert_receive {:relay, %{op: "found", request: ^request, owners: found}}
      assert Enum.sort(found) == Enum.sort(Enum.map(owners, &elem(&1, 0)))
      # Reauthentication does not resurrect the identity's old advertisements.
      {first, first_pid} = hd(owners)
      :ok = :ba_reception_sessions.attach(first, first_pid)
      assert :ok = :ba_reception_sessions.command(client, self(), lookup)
      assert_receive {:relay, %{op: "found", request: ^request, owners: remaining}}
      assert remaining == [elem(List.last(owners), 0)]
      assert :ok = :ba_reception_sessions.command(client, self(), %{lookup | "mailbox" => String.duplicate("0", 32)})
      assert_receive {:relay, %{op: "found", request: ^request, owners: []}}
      for {id, pid} <- owners do
        :ok = :ba_reception_sessions.command(id, pid, %{"op" => "close", "mailbox" => cap})
      end
      assert :ok = :ba_reception_sessions.command(client, self(), lookup)
      assert_receive {:relay, %{op: "found", request: ^request, owners: []}}
    after
      for {_, pid} <- owners, do: send(pid, :stop)
    end
  end
end
