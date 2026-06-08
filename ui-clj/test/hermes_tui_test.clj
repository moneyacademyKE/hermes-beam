(ns hermes-tui-test
  (:require
   [clojure.test :refer [deftest is testing]]
   [hermes-tui :as tui]))

(deftest tool-trail-label-test
  (testing "Formats tool trail label to capitalized words"
    (is (= "Read File" (tui/tool-trail-label "read_file")))
    (is (= "Write To File" (tui/tool-trail-label "write_to_file")))
    (is (= "" (tui/tool-trail-label "")))))

(deftest compact-preview-test
  (testing "Truncates long context text to preview width"
    (is (= "hello world" (tui/compact-preview "hello world" 20)))
    (is (= "hello..." (tui/compact-preview "hello world" 8)))
    (is (= "" (tui/compact-preview "" 10)))))

(deftest format-tool-call-test
  (testing "Formats tool calls with preview arguments"
    (is (= "Read File(\"abc.txt\")" (tui/format-tool-call "read_file" "abc.txt")))
    (is (= "Get Status" (tui/format-tool-call "get_status" "")))))

(deftest build-tool-trail-line-test
  (testing "Assembles a single tool trail line with status indicator"
    (is (= "Read File(\"abc.txt\") (1.5s) :: notes ✓"
           (tui/build-tool-trail-line "read_file" "abc.txt" false "notes" 1.5)))
    (is (= "Read File(\"abc.txt\") ✗"
           (tui/build-tool-trail-line "read_file" "abc.txt" true "" nil)))))

(deftest to-transcript-messages-test
  (testing "Accumulates tool trails into the subsequent assistant message"
    (let [rows [{:role "user" :text "run tool"}
                {:role "tool" :name "run_cmd" :context "ls" :error false :note "files" :duration 0.5}
                {:role "assistant" :text "done"}]
          msgs (tui/to-transcript-messages rows)]
      (is (= 2 (count msgs)))
      (is (= "user" (:role (first msgs))))
      (is (= "assistant" (:role (second msgs))))
      (is (= ["Run Cmd(\"ls\") (0.5s) :: files ✓"] (:tools (second msgs)))))))

(deftest wrap-line-test
  (testing "Wraps single lines within width constraints"
    (is (= ["hello" "world"] (tui/wrap-line "hello world" 6)))))

(deftest wrap-text-test
  (testing "Wraps multi-line strings within width constraints"
    (is (= ["hello" "world" "goodbye" "world"]
           (tui/wrap-text "hello world\ngoodbye world" 8)))))

(deftest handle-rpc-response-test
  (testing "Resolves session information on session.resume or session.create responses"
    (let [state {:width 80 :cwd "/orig" :messages [] :model "default"}
          result {:session_id "new-sid"
                  :messages [{:role "user" :text "hi"}]
                  :info {:cwd "/new" :model "hermes-v3" :provider "openai" :usage {:input_tokens 10 :output_tokens 20}}}
          next-state (tui/handle-rpc-response state 123 result nil)]
      (is (= "new-sid" (:session-id next-state)))
      (is (= "/new" (:cwd next-state)))
      (is (= "hermes-v3" (:model next-state)))
      (is (= "ready" (:status next-state))))))
