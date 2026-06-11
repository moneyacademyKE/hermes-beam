(require '[clojure.java.io :as io])
(require '[clojure.string :as str])

(defn read-yaml [filepath]
  (with-open [rdr (io/reader filepath)]
    (reduce (fn [acc line]
              (let [[k v] (str/split line #":")]
                (if v
                  (assoc acc (keyword (str/trim k)) (str/trim v))
                  acc)))
            {}
            (line-seq rdr))))

(defn validate-keys [data required-keys]
  (let [missing-keys (remove #(contains? data (keyword %)) required-keys)]
    missing-keys))

(def required-keys ["requiredKey1" "requiredKey2" "requiredKey3"])
(def yaml-data (read-yaml "cli-config.yaml.example"))
(println (validate-keys yaml-data required-keys))