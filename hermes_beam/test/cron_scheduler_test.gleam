import cron_scheduler.{CronJob}
import gleam/erlang/process
import gleam/option.{None}
import hermes_time.{type DateTime, DateTime}
import state_actor

// Mock DateTime constructor helper
fn make_datetime(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  _day_of_week: Int, // 1-7 (Mon-Sun)
) -> DateTime {
  DateTime(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    second: second,
    offset_seconds: 0,
    timezone_name: "UTC",
  )
}

pub fn cron_match_test() {
  // Test basic wildcards
  let dt = make_datetime(2026, 6, 14, 9, 30, 0, 7) // Sunday
  let assert True = cron_scheduler.match_cron("* * * * *", dt, 7)

  // Test exact matching (minute and hour)
  let assert True = cron_scheduler.match_cron("30 9 * * *", dt, 7)
  let assert False = cron_scheduler.match_cron("0 9 * * *", dt, 7)
  let assert False = cron_scheduler.match_cron("30 10 * * *", dt, 7)

  // Test lists (comma separated)
  let assert True = cron_scheduler.match_cron("15,30,45 * * * *", dt, 7)
  let assert False = cron_scheduler.match_cron("15,45 * * * *", dt, 7)

  // Test ranges
  let assert True = cron_scheduler.match_cron("25-35 * * * *", dt, 7)
  let assert False = cron_scheduler.match_cron("0-10 * * * *", dt, 7)

  // Test steps (e.g. */15)
  let assert True = cron_scheduler.match_cron("*/15 * * * *", dt, 7)
  let assert False = cron_scheduler.match_cron("*/20 * * * *", dt, 7)
  let assert True = cron_scheduler.match_cron("*/10 9 * * *", dt, 7)

  // Test day of week matching (Sunday is 0 or 7 in cron, 7 in Erlang)
  let assert True = cron_scheduler.match_cron("* * * * 0", dt, 7)
  let assert True = cron_scheduler.match_cron("* * * * 7", dt, 7)
  let assert True = cron_scheduler.match_cron("* * * * 0,7", dt, 7)
  let assert False = cron_scheduler.match_cron("* * * * 1-5", dt, 7) // Monday-Friday

  // Test day of week on Wednesday (Wednesday = 3)
  let dt_wed = make_datetime(2026, 6, 17, 12, 0, 0, 3)
  let assert True = cron_scheduler.match_cron("* * * * 3", dt_wed, 3)
  let assert True = cron_scheduler.match_cron("* * * * 1-5", dt_wed, 3)
  let assert False = cron_scheduler.match_cron("* * * * 0,6,7", dt_wed, 3)
}

pub fn cron_scheduler_actor_test() {
  // Start the scheduler actor (using a dummy state actor / credentials)
  let self_subj = process.new_subject()
  let mock_state_actor = state_actor_from_subject(self_subj)
  let assert Ok(sched) = cron_scheduler.start(
    mock_state_actor,
    "mock-key",
    "mock-url",
    "mock-model",
  )

  // List jobs should start empty
  let assert [] = cron_scheduler.list_jobs(sched)

  // Add a job
  let job = CronJob(
    id: "job-1",
    schedule: "*/5 * * * *",
    prompt: "Hello world",
    last_run: None,
  )
  let assert Ok(Nil) = cron_scheduler.add_job(sched, job)

  // List jobs should now return our job
  let assert [j1] = cron_scheduler.list_jobs(sched)
  let assert "job-1" = j1.id
  let assert "*/5 * * * *" = j1.schedule

  // Remove the job
  let assert Ok(Nil) = cron_scheduler.remove_job(sched, "job-1")

  // List jobs should be empty again
  let assert [] = cron_scheduler.list_jobs(sched)
}

// FFI or mock helper for StateActor in tests
@external(erlang, "hermes_time_ffi", "identity")
fn state_actor_from_subject(x: process.Subject(a)) -> state_actor.StateActor
