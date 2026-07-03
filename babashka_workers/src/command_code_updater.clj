(ns command-code-updater
  (:require [cheshire.core :as json]
            [babashka.http-client :as http]
            [babashka.process :as p]
            [clojure.string :as str]))

(defn- get-local-version []
  (try
    (let [{:keys [out exit]} (p/sh "command-code" "--version")]
      (if (= exit 0)
        (str/trim out)
        nil))
    (catch Exception _ nil)))

(defn- get-latest-version []
  (try
    (let [resp (http/get "https://registry.npmjs.org/command-code/latest")
          body (:body resp)
          parsed (json/parse-string body true)]
      (:version parsed))
    (catch Exception _ nil)))

(defn- version-older? [local latest]
  (let [parse-v (fn [v] (mapv #(Integer/parseInt %) (str/split v #"\.")))
        l-parts (parse-v local)
        r-parts (parse-v latest)]
    (neg? (compare l-parts r-parts))))

(defn -main [& args]
  (println "Checking command-code version status...")
  (let [local (get-local-version)
        latest (get-latest-version)]
    (cond
      (nil? local)
      (do
        (println "command-code is not installed locally.")
        (println "Recommended install command: pnpm i -g command-code@latest"))

      (nil? latest)
      (println "Could not fetch latest version from npm registry. Current local version:" local)

      (= local latest)
      (println "✓ command-code is up to date. Version:" local)

      (version-older? local latest)
      (do
        (println "▲ A newer version of command-code is available!")
        (println "  Local Version: " local)
        (println "  Latest Version:" latest)
        (println "  Please run the following command to update:")
        (println "  pnpm i -g command-code@latest"))

      :else
      (println "Local version" local "is newer than registry version" latest "."))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
