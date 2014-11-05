defmodule Exq.Manager do
  require Logger
  use GenServer

  @default_name :exq_manager

  defmodule State do
    defstruct pid: nil, redis: nil, busy_workers: nil, namespace: nil,
              queues: nil, poll_timeout: nil, stats: nil
  end

##===========================================================
## gen server callbacks
##===========================================================

  def init([opts]) do
    host = Keyword.get(opts, :host, Exq.Config.get(:host, '127.0.0.1'))
    port = Keyword.get(opts, :port, Exq.Config.get(:port, 6379))
    database = Keyword.get(opts, :database, Exq.Config.get(:database, 0))
    password = Keyword.get(opts, :password, Exq.Config.get(:password, ''))
    queues = Keyword.get(opts, :queues, Exq.Config.get(:queues, ["default"]))
    namespace = Keyword.get(opts, :namespace, Exq.Config.get(:namespace, "exq"))
    poll_timeout = Keyword.get(opts, :poll_timeout, Exq.Config.get(:poll_timeout, 50))
    reconnect_on_sleep = Keyword.get(opts, :reconnect_on_sleep, Exq.Config.get(:reconnect_on_sleep, 100))

    {:ok, redis} = :eredis.start_link(host, port, database, password, reconnect_on_sleep)

    {:ok, stats} =  GenServer.start_link(Exq.Stats, {redis}, [])

    state = %State{redis: redis,
                      busy_workers: [],
                      namespace: namespace,
                      queues: queues,
                      pid: self(),
                      poll_timeout: poll_timeout,
                      stats: stats}
    {:ok, state, 0}
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, [opts], [{:name, name}])
  end

  def handle_call({:enqueue, queue, worker, args}, _from, state) do
    jid = Exq.RedisQueue.enqueue(state.redis, state.namespace, queue, worker, args)
    {:reply, {:ok, jid}, state, 0}
  end

  def handle_cast({:failure, error, job}, state) do
    GenServer.cast(state.stats, {:record_failure, state.namespace, error, job})
    {:noreply, state, 0}
  end

  def handle_cast({:success, job}, state) do
    GenServer.cast(state.stats, {:record_processed, state.namespace, job})
    {:noreply, state, 0}
  end

  def handle_call({:find_failed, jid}, _from, state) do
    {:ok, job, idx} = Exq.Stats.find_failed(state.redis, state.namespace, jid)
    {:reply, {:ok, job, idx}, state, 0}
  end

  def handle_call({:find_job, queue, jid}, _from, state) do
    {:ok, job, idx} = Exq.RedisQueue.find_job(state.redis, state.namespace, jid, queue)
    {:reply, {:ok, job, idx}, state, 0}
  end

  def handle_call({:stop}, _from, state) do
    { :stop, :normal, :ok, state }
  end

  def handle_info(:timeout, state) do
    {updated_state, timeout} = dequeue_and_dispatch(state)
    {:noreply, updated_state, timeout}
  end

  def code_change(_old_version, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, state) do
    GenServer.call(state.stats, {:stop})
    :eredis.stop(state.redis)
    :ok
  end

  def handle_call(_request, _from, state) do
    Logger.error("UKNOWN CALL")
    {:reply, :unknown, state, 0}
  end

  def handle_cast(_request, state) do
    Logger.error("UKNOWN CAST")
    {:noreply, state, 0}
  end

##===========================================================
## Internal Functions
##===========================================================

  def dequeue_and_dispatch(state) do
    case dequeue(state.redis, state.namespace, state.queues) do
      :none -> {state, state.poll_timeout}
      job -> {dispatch_job(state, job), 0}
    end
  end

  def dequeue(redis, namespace, queues) do
    Exq.RedisQueue.dequeue(redis, namespace, queues)
  end

  def dispatch_job(state, job) do
    {:ok, worker} = Exq.Worker.start(job, state.pid)
    Exq.Worker.work(worker)
    state
  end

  def default_name, do: @default_name
end
