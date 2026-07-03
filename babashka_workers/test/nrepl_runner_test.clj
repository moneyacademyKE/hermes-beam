(ns nrepl-runner-test
  (:require [clojure.test :refer [deftest is testing run-tests]]
            [io.nextdoc.tools :as tools]
            [io.nextdoc.clean :as clean]))

(deftest parse-test-entries-test
  (testing "Parsing mixed test entries (namespaces vs individual tests)"
    (let [parse-entries #'io.nextdoc.tools/parse-test-entries
          entries ["my.project.core-test" "my.project.utils-test/specific-test"]
          result (parse-entries entries)]
      (is (= #{:namespaces :individual-tests} (set (keys result))))
      (is (= ['my.project.core-test] (:namespaces result)))
      (is (= [{:namespace 'my.project.utils-test :test-name 'specific-test}]
             (:individual-tests result))))))

(deftest clean-stack-trace-test
  (testing "Stack trace filtering preserves application frames and filters framework frames"
    (let [raw-output (clojure.string/join "\n"
                       ["Testing my.project.core-test"
                        "ERROR in (some-test)"
                        "expected: 1"
                        "  actual: 2"
                        "	at my.project.core/func (core.clj:12)"
                        "	at sci.impl.interpreter/eval (interpreter.clj:34)"
                        "	at clojure.lang.Compiler.eval (Compiler.java:123)"
                        "Ran 1 tests containing 1 assertions."])
          cleaned (clean/clean-test-output raw-output)]
      (is (some #(clojure.string/includes? % "my.project.core/func") cleaned))
      (is (not (some #(clojure.string/includes? % "sci.impl.interpreter") cleaned)))
      (is (not (some #(clojure.string/includes? % "clojure.lang.Compiler") cleaned))))))

(defn -main [& args]
  (let [summary (run-tests 'nrepl-runner-test)]
    (System/exit (if (pos? (+ (:fail summary) (:error summary))) 1 0))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
