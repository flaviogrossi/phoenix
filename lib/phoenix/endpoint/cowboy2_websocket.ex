defmodule Phoenix.Endpoint.Cowboy2WebSocket do
  # Implementation of the WebSocket transport for Cowboy.
  @moduledoc false

  @behaviour :cowboy_websocket
  @connection Plug.Adapters.Cowboy2.Conn
  @already_sent {:plug_conn, :sent}

  def init(req, {module, opts}) do
    # Is this too brittle?
    conn = @connection.conn(req)
    case module.init(conn, opts) do
      {:ok, _, _} ->
        {_, socket, _} = opts
        %{websocket: {_, config}} = socket.__transports__
        timeout = Keyword.fetch!(config, :timeout)
        {:cowboy_websocket, req, {module, req, opts}, %{idle_timeout: timeout}}
      {:error, %{adapter: {@connection, req}}} ->
        {:error, req}
    end
  end

  def resume(module, fun, args) do
    try do
      apply(module, fun, args)
    catch
      kind, [{:reason, reason}, {:mfa, _mfa}, {:stacktrace, stack} | _rest] ->
        reason = format_reason(kind, reason, stack)
        exit({reason, {__MODULE__, :resume, []}})
    else
      {:suspend, module, fun, args} ->
        {:suspend, __MODULE__, :resume, [module, fun, args]}
      _ ->
        # We are forcing a shutdown exit because we want to make
        # sure all transports exits with reason shutdown to guarantee
        # all channels are closed.
        exit(:shutdown)
    end
  end

  defp format_reason(:exit, reason, _), do: reason
  defp format_reason(:throw, reason, stack), do: {{:nocatch, reason}, stack}
  defp format_reason(:error, reason, stack), do: {reason, stack}

  ## Websocket callbacks

  def websocket_init({module, req, opts}) do
    conn = @connection.conn(req)
    try do
      case module.init(conn, opts) do
        {:ok, %{adapter: {@connection, _}}, {_handler, args}} ->
          {:ok, state, _timeout} = module.ws_init(args)
          {:ok, {module, state}}
      end
    catch
      kind, reason ->
        # Although we are not performing a call, we are using the call
        # function for now so it is properly handled in error reports.
        mfa = {module, :call, [conn, opts]}
      {__MODULE__, req, {:error, mfa, kind, reason, System.stacktrace}}
    after
      receive do
        @already_sent -> :ok
      after
        0 -> :ok
      end
    end
  end

  def websocket_handle({opcode = :text, payload}, {handler, state}) do
    handle_reply handler, handler.ws_handle(opcode, payload, state)
  end
  def websocket_handle({opcode = :binary, payload}, {handler, state}) do
    handle_reply handler, handler.ws_handle(opcode, payload, state)
  end
  def websocket_handle(_other, {handler, state}) do
    {:ok, {handler, state}}
  end

  def websocket_info(message, {handler, state}) do
    handle_reply handler, handler.ws_info(message, state)
  end

  def terminate({:error, :closed}, _req, {handler, state}) do
    handler.ws_close(state)
    :ok
  end
  def terminate({:remote, :closed}, _req, {handler, state}) do
    handler.ws_close(state)
    :ok
  end
  def terminate({:remote, code, _}, _req, {handler, state})
      when code in 1000..1003 or code in 1005..1011 or code == 1015 do
    handler.ws_close(state)
    :ok
  end
  def terminate(:remote, _req, {handler, state}) do
    handler.ws_close(state)
    :ok
  end
  def terminate(reason, _req, {handler, state}) do
    handler.ws_close(state) # do we want to do this?
    handler.ws_terminate(reason, state)
    :ok
  end

  defp handle_reply(handler, {:shutdown, new_state}) do
    {:stop, {handler, new_state}}
  end
  defp handle_reply(handler, {:ok, new_state}) do
    {:ok, {handler, new_state}}
  end
  defp handle_reply(handler, {:reply, {opcode, payload}, new_state}) do
    {:reply, {opcode, payload}, {handler, new_state}}
  end
end
