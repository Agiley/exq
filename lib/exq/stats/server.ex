defmodule Exq.Stats.Server do
  use GenServer
  use Timex
  alias Exq.Redis.Connection
  alias Exq.Redis.JobQueue
  alias Exq.Support.Json
  alias Exq.Support.Binary
  alias Exq.Stats.Process
  require Logger

  @default_name :exq_stats

  defmodule State do
    defstruct redis: nil
  end

  def add_process(pid, namespace, worker, host, job) do
    GenServer.cast(pid, {:add_process, namespace, %Process{pid: worker, host: host, job: job, started_at: DateFormat.format!(Date.local, "{ISO}")}})
  end

##===========================================================
## gen server callbacks
##===========================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, [opts], [{:name, name}])
  end

  # These are the callbacks that GenServer.Behaviour will use
  def init([opts]) do
    {:ok, %State{redis: Keyword.get(opts, :redis)}}
  end

  def default_name, do: @default_name

  def handle_cast({:add_process, namespace, process}, state) do
    add_process(state.redis, namespace, process)
    {:noreply, state}
  end

  def handle_cast({:record_processed, namespace, job}, state) do
    record_processed(state.redis, namespace, job)
    {:noreply, state}
  end

  def handle_cast({:record_failure, namespace, error, job}, state) do
    record_failure(state.redis, namespace, error, job)
    {:noreply, state}
  end

  def handle_cast({:process_terminated, namespace, hostname, pid}, state) do
    {:ok, _} = remove_process(state.redis, namespace, hostname, pid)
    {:noreply, state}
  end

  def handle_cast(data, state) do
    Logger.error("INVALID MESSAGE #{data}")
    {:noreply, state}
  end

  def handle_call({:stop}, _from, state) do
    { :stop, :normal, :ok, state }
  end

  def handle_info(info, state) do
    Logger.error("INVALID MESSAGE #{info}")
    {:noreply, state}
  end

  def terminate(_reason, _state) do
    {:ok}
  end

  def code_change(_old_version, state, _extra) do
    {:ok, state}
  end

##===========================================================
## Methods
##===========================================================

  def get(redis, namespace, key) do
    case Connection.get!(redis, JobQueue.full_key(namespace, "stat:#{key}")) do
      :undefined ->
        0
      count ->
        count
    end
  end

  def busy(redis, namespace) do
    Connection.scard!(redis, JobQueue.full_key(namespace, "processes"))
  end

  def processes(redis, namespace) do
    Connection.smembers!(redis, JobQueue.full_key(namespace, "processes"))
  end

  def add_process(redis, namespace, process) do
    pid = to_string(:io_lib.format("~p", [process.pid]))

    process = Enum.into([{:pid, pid}, {:host, process.host}, {:job, process.job}, {:started_at, process.started_at}], HashDict.new)
    json = Json.encode!(process)

    Connection.sadd!(redis, JobQueue.full_key(namespace, "processes"), json)
    :ok
  end

  def remove_process(redis, namespace, hostname, pid) do
    pid = to_string(:io_lib.format("~p", [pid]))

    processes = Connection.smembers!(redis, JobQueue.full_key(namespace, "processes"))

    finder = fn(p) ->
      case Json.decode(p) do
        { :ok, proc } -> (Dict.get(proc, "pid") == pid) && (Dict.get(proc, "host") == hostname)
        { :error, _ } -> false
      end
    end

    proc = Enum.find(processes, finder)

    case proc do
      nil ->
        {:not_found, nil}
      p ->
        Connection.srem!(redis, JobQueue.full_key(namespace, "processes"), proc)
        {:ok, p}
    end

  end

  def record_processed(redis, namespace, _job) do
    count = Connection.incr!(redis, JobQueue.full_key(namespace, "stat:processed"))

    time = DateFormat.format!(Date.universal, "%Y-%m-%d %T %z", :strftime)
    Connection.incr!(redis, JobQueue.full_key(namespace, "stat:processed_rt:#{time}"))
    Connection.expire!(redis, JobQueue.full_key(namespace, "stat:processed_rt:#{time}"), 120)

    date = DateFormat.format!(Date.universal, "%Y-%m-%d", :strftime)
    Connection.incr!(redis, JobQueue.full_key(namespace, "stat:processed:#{date}"))
    {:ok, count}
  end

  def record_failure(redis, namespace, error, json) do
    count = Connection.incr!(redis, JobQueue.full_key(namespace, "stat:failed"))

    time = DateFormat.format!(Date.universal, "%Y-%m-%d %T %z", :strftime)
    Connection.incr!(redis, JobQueue.full_key(namespace, "stat:failed_rt:#{time}"))
    Connection.expire!(redis, JobQueue.full_key(namespace, "stat:failed_rt:#{time}"), 120)


    date = DateFormat.format!(Date.universal, "%Y-%m-%d", :strftime)
    Connection.incr!(redis, JobQueue.full_key(namespace, "stat:failed:#{date}"))

    failed_at = DateFormat.format!(Date.local, "{ISO}")

    job = Exq.Support.Job.from_json(json)
    job = Enum.into([{:failed_at, failed_at}, {:error_class, "ExqGenericError"}, {:error_message, error}, {:queue, job.queue}, {:class, job.class}, {:args, job.args}, {:jid, job.jid}, {:enqueued_at, job.enqueued_at}], HashDict.new)

    job_json = Json.encode!(job)

    Connection.rpush!(redis, JobQueue.full_key(namespace, "failed"), job_json)

    {:ok, count}
  end

  def find_failed(redis, namespace, jid) do
    Connection.lrange!(redis, JobQueue.full_key(namespace, "failed"), 0, -1)
      |> JobQueue.find_job(jid)
  end

  def remove_queue(redis, namespace, queue) do
    Connection.srem!(redis, JobQueue.full_key(namespace, "queues"), queue)
    Connection.del!(redis, JobQueue.queue_key(namespace, queue))
  end

  def remove_failed(redis, namespace, jid) do
    Connection.decr!(redis, JobQueue.full_key(namespace, "stat:failed"))
    {:ok, failure, _idx} = find_failed(redis, namespace, jid)
    Connection.lrem!(redis, JobQueue.full_key(namespace, "failed"), failure)
  end

  def clear_failed(redis, namespace) do
    Connection.set!(redis, JobQueue.full_key(namespace, "stat:failed"), 0)
    Connection.del!(redis, JobQueue.full_key(namespace, "failed"))
  end

  def clear_processes(redis, namespace) do
    Connection.del!(redis, JobQueue.full_key(namespace, "processes"))
  end

  def realtime_stats(redis, namespace) do
    failure_keys = Connection.keys!(redis, JobQueue.full_key(namespace, "stat:failed_rt:*"))
    failures = for key <- failure_keys do
      date = Binary.take_prefix(key, JobQueue.full_key(namespace, "stat:failed_rt:"))
      count = Connection.get!(redis, key)
      {date, count}
    end

    success_keys = Connection.keys!(redis, JobQueue.full_key(namespace, "stat:processed_rt:*"))
    successes = for key <- success_keys do
      date = Binary.take_prefix(key, JobQueue.full_key(namespace, "stat:processed_rt:"))
      count = Connection.get!(redis, key)
      {date, count}
    end

    {:ok, failures, successes}
  end

end
