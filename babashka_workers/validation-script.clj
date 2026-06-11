(require '[clojure.yaml :as yaml]
        '[clojure.java.io :as io])

(def required-keys #{"requiredKey1" "requiredKey2" "requiredKey3"})

(defn validate-config [config]
  (let [display (get config "display")
        display-keys (set (map #(first (seq %)) display))
        missing-keys (clojure.set/difference required-keys display-keys)]
    (if (empty? missing-keys)
      (println "Validation passed: All required keys are present.")
      (println "Validation failed: Missing keys:" missing-keys))))

(defn -main []
  (let [config (yaml/parse-string (slurp "cli-config.yaml.example"))]
    (validate-config config)))

(-main)