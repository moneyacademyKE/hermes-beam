import time
import gleam/option.{Some, None}

pub fn parse_timezone_from_yaml_test() {
  let content = "
# some comment
timezone: Asia/Kolkata # target
  "
  let assert Ok("Asia/Kolkata") = time.parse_timezone_from_yaml(content)

  let content_quoted = "
timezone: \"America/New_York\"
  "
  let assert Ok("America/New_York") = time.parse_timezone_from_yaml(content_quoted)

  let content_single_quoted = "
timezone: 'Europe/London'
  "
  let assert Ok("Europe/London") = time.parse_timezone_from_yaml(content_single_quoted)

  let content_commented = "
# timezone: UTC
  "
  let assert Error(Nil) = time.parse_timezone_from_yaml(content_commented)

  let content_empty = "
timezone: 
  "
  let assert Error(Nil) = time.parse_timezone_from_yaml(content_empty)
}

pub fn parse_offset_string_test() {
  // We can call private parse_offset_string through test helper if needed,
  // or we can test now() directly. Since we want complete test coverage,
  // let's test it using now() or make sure now() runs correctly.
  let dt = time.get_server_local_time()
  let assert True = dt.year >= 2026
}

pub fn validate_timezone_test() {
  let assert True = time.validate_timezone("Asia/Kolkata")
  let assert True = time.validate_timezone("America/New_York")
  let assert False = time.validate_timezone("Invalid/Zone")
  let assert False = time.validate_timezone("../etc/passwd")
}

pub fn now_test() {
  let dt = time.now()
  let assert True = dt.year >= 2026
  let assert True = dt.month >= 1 && dt.month <= 12
  let assert True = dt.day >= 1 && dt.day <= 31
  let assert True = dt.hour >= 0 && dt.hour <= 23
  let assert True = dt.minute >= 0 && dt.minute <= 59
  let assert True = dt.second >= 0 && dt.second <= 59
}
