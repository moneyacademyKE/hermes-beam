import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import hermes_agent
import hermes_exec
import hermes_time.{type DateTime}
import state_actor.{type StateActor}

// ─── Types ────────────────────────────────────────────────────────────────────

pub type CronJob {
  CronJob(
    id: String,
    schedule: String,
    prompt: String,
    last_run: Option(Int),
  )
}

pub type Message {
  AddJob(job: CronJob, reply_to: Subject(Result(Nil, String)))
  RemoveJob(id: String, reply_to: Subject(Result(Nil, String)))
  ListJobs(reply_to: Subject(List(CronJob)))
  Tick
}

pub type SchedulerState {
  SchedulerState(
    jobs: List(CronJob),
    db_conn: StateActor,
    api_key: String,
    base_url: String,
    model: String,
    self_subject: Subject(Message),
  )
}

pub opaque type CronScheduler {
  CronScheduler(subject: Subject(Message))
}

// ─── External calendar FFI ───────────────────────────────────────────────────

@external(erlang, "calendar", "day_of_the_week")
pub fn erl_day_of_the_week(year: Int, month: Int, day: Int) -> Int

@external(erlang, "calendar", "datetime_to_gregorian_seconds")
pub fn erl_datetime_to_gregorian_seconds(dt: #(#(Int, Int, Int), #(Int, Int, Int))) -> Int

// ─── Constructor ──────────────────────────────────────────────────────────────

pub fn start(
  db_conn: StateActor,
  api_key: String,
  base_url: String,
  model: String,
) -> Result(CronScheduler, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subj) {
    let initial_state =
      SchedulerState(
        jobs: [],
        db_conn: db_conn,
        api_key: api_key,
        base_url: base_url,
        model: model,
        self_subject: subj,
      )

    // Schedule the first Tick after 5 seconds to get the loop started
    let _timer = process.send_after(subj, 5000, Tick)

    let selector = process.new_selector() |> process.select(subj)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subj)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { CronScheduler(started.data) })
}

// ─── Client API ───────────────────────────────────────────────────────────────

pub fn add_job(
  scheduler: CronScheduler,
  job: CronJob,
) -> Result(Nil, String) {
  actor.call(scheduler.subject, 5000, AddJob(job, _))
}

pub fn remove_job(
  scheduler: CronScheduler,
  id: String,
) -> Result(Nil, String) {
  actor.call(scheduler.subject, 5000, RemoveJob(id, _))
}

pub fn list_jobs(scheduler: CronScheduler) -> List(CronJob) {
  actor.call(scheduler.subject, 5000, ListJobs)
}

// ─── Cron Parsing & Matching ──────────────────────────────────────────────────

fn match_field_part(part: String, value: Int) -> Bool {
  case part {
    "*" -> True
    _ -> {
      case string.split_once(part, on: "-") {
        Ok(#(start_str, end_str)) -> {
          case int.parse(start_str), int.parse(end_str) {
            Ok(start), Ok(end) -> value >= start && value <= end
            _, _ -> False
          }
        }
        Error(_) -> {
          case string.split_once(part, on: "*/") {
            Ok(#("", step_str)) -> {
              case int.parse(step_str) {
                Ok(step) -> value % step == 0
                Error(_) -> False
              }
            }
            _ -> {
              case int.parse(part) {
                Ok(val) -> val == value
                Error(_) -> False
              }
            }
          }
        }
      }
    }
  }
}

fn match_dow_part(part: String, erl_day: Int) -> Bool {
  // erl_day is 1-7 (Mon-Sun)
  // standard cron Sunday is 0 or 7
  let cron_day_0 = case erl_day {
    7 -> 0
    other -> other
  }
  let cron_day_7 = erl_day

  case part {
    "*" -> True
    _ -> {
      case string.split_once(part, on: "-") {
        Ok(#(start_str, end_str)) -> {
          case int.parse(start_str), int.parse(end_str) {
            Ok(start), Ok(end) -> {
              { cron_day_0 >= start && cron_day_0 <= end }
              || { cron_day_7 >= start && cron_day_7 <= end }
            }
            _, _ -> False
          }
        }
        Error(_) -> {
          case string.split_once(part, on: "*/") {
            Ok(#("", step_str)) -> {
              case int.parse(step_str) {
                Ok(step) -> cron_day_0 % step == 0 || cron_day_7 % step == 0
                Error(_) -> False
              }
            }
            _ -> {
              case int.parse(part) {
                Ok(val) -> val == cron_day_0 || val == cron_day_7
                Error(_) -> False
              }
            }
          }
        }
      }
    }
  }
}

pub fn match_cron(
  expression: String,
  datetime: DateTime,
  erl_day_of_week: Int,
) -> Bool {
  let fields = string.split(expression, on: " ")
  case fields {
    [min_f, hr_f, dom_f, mon_f, dow_f] -> {
      let match_min =
        list.any(string.split(min_f, on: ","), fn(p) {
          match_field_part(p, datetime.minute)
        })
      let match_hr =
        list.any(string.split(hr_f, on: ","), fn(p) {
          match_field_part(p, datetime.hour)
        })
      let match_dom =
        list.any(string.split(dom_f, on: ","), fn(p) {
          match_field_part(p, datetime.day)
        })
      let match_mon =
        list.any(string.split(mon_f, on: ","), fn(p) {
          match_field_part(p, datetime.month)
        })
      let match_dow =
        list.any(string.split(dow_f, on: ","), fn(p) {
          match_dow_part(p, erl_day_of_week)
        })

      match_min && match_hr && match_dom && match_mon && match_dow
    }
    _ -> False
  }
}

// ─── Actor Message Handler ────────────────────────────────────────────────────

fn handle_message(
  state: SchedulerState,
  message: Message,
) -> actor.Next(SchedulerState, Message) {
  case message {
    AddJob(job, reply_to) -> {
      let next_jobs = [job, ..state.jobs]
      process.send(reply_to, Ok(Nil))
      actor.continue(SchedulerState(..state, jobs: next_jobs))
    }

    RemoveJob(id, reply_to) -> {
      let next_jobs = list.filter(state.jobs, fn(j) { j.id != id })
      process.send(reply_to, Ok(Nil))
      actor.continue(SchedulerState(..state, jobs: next_jobs))
    }

    ListJobs(reply_to) -> {
      process.send(reply_to, state.jobs)
      actor.continue(state)
    }

    Tick -> {
      let dt = hermes_time.now()
      let dow = erl_day_of_the_week(dt.year, dt.month, dt.day)

      // Compute current minute as Gregorian seconds (minute-resolution timestamp)
      let current_minute_secs =
        erl_datetime_to_gregorian_seconds(
          #(#(dt.year, dt.month, dt.day), #(dt.hour, dt.minute, 0)),
        )

      // Check matching jobs and trigger them if they haven't run this minute
      let updated_jobs =
        list.map(state.jobs, fn(job) {
          case match_cron(job.schedule, dt, dow) {
            True -> {
              let already_ran = case job.last_run {
                Some(lr) -> lr == current_minute_secs
                None -> False
              }

              case already_ran {
                True -> job
                False -> {
                  // Trigger the job asynchronously
                  trigger_job_async(job, current_minute_secs, state)
                  CronJob(..job, last_run: Some(current_minute_secs))
                }
              }
            }
            False -> job
          }
        })

      // Schedule the next Tick in 10 seconds (for fast responsiveness)
      let _timer = process.send_after(state.self_subject, 10000, Tick)

      actor.continue(SchedulerState(..state, jobs: updated_jobs))
    }
  }
}

fn trigger_job_async(
  job: CronJob,
  current_minute_secs: Int,
  state: SchedulerState,
) -> Nil {
  let session_id =
    "cron-" <> job.id <> "-" <> int.to_string(current_minute_secs)

  let _ =
    process.spawn(fn() {
      // 1. Initialize execution environment for this session
      let exec_env = hermes_exec.new_terminal_env("", 120_000, [])
      let exec_env = hermes_exec.init_session(exec_env)

      // 2. Initialize AgentState
      let agent_res =
        hermes_agent.new_agent_state(
          session_id,
          state.model,
          "",
          state.db_conn,
          exec_env,
          state.api_key,
          state.base_url,
          "You are Antigravity, a scheduled automation agent. Execute the task.",
          90,
          None,
          None,
          None,
        )

      case agent_res {
        Ok(agent) -> {
          // Create the session in DB
          let _ =
            state_actor.create_session(
              state.db_conn,
              session_id,
              "cron",
              state.model,
              "Scheduled automation agent",
              int.to_float(current_minute_secs),
            )

          // Execute the conversation
          case hermes_agent.run_conversation(agent, job.prompt) {
            Ok(_) -> {
              io.println("Successfully ran cron job: " <> job.id)
              Nil
            }
            Error(err) -> {
              io.println("Failed running cron job: " <> job.id <> " - " <> err)
              Nil
            }
          }
        }
        Error(err) -> {
          io.println("Failed initializing agent state for cron job: " <> job.id <> " - " <> err)
          Nil
        }
      }
    })

  Nil
}
