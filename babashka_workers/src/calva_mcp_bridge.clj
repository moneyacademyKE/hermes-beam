(ns calva-mcp-bridge
  (:require [clojure.java.io :as io]
             [clojure.string :as str])
  (:import (java.net InetSocketAddress Socket SocketTimeoutException)
            (java.io InputStream OutputStream)))

(defn- env-int [name default]
  (try
    (if-let [v (System/getenv name)]
      (Integer/parseInt v)
      default)
    (catch Exception _ default)))

(defn- get-port-from-file [port-file]
  (try
    (let [content (str/trim (slurp port-file))]
      (Integer/parseInt content))
    (catch Exception _ nil)))

(defn- pipe [^InputStream in ^OutputStream out]
  (let [buffer (byte-array 4096)]
    (try
      (loop []
        (let [n (.read in buffer)]
          (when (pos? n)
            (.write out buffer 0 n)
            (.flush out)
            (recur))))
      (catch SocketTimeoutException _ nil)
      (catch Exception _ nil))))

(defn- connect-socket [host port connect-timeout-ms read-timeout-ms]
  (let [socket (Socket.)]
    (try
      (.connect socket (InetSocketAddress. host port) connect-timeout-ms)
      (.setSoTimeout socket read-timeout-ms)
      socket
      (catch Exception e
        (.close socket)
        (throw e)))))

(defn -main [& args]
  (let [workspace-root (or (first args) "..")
        port-file (io/file workspace-root ".calva" "mcp-server" "port")
        connect-timeout-ms (env-int "CALVA_MCP_CONNECT_TIMEOUT_MS" 5000)
        read-timeout-ms (env-int "CALVA_MCP_READ_TIMEOUT_MS" 0)]
    (if-not (.exists port-file)
      (do
        (binding [*out* *err*]
          (println "Error: Calva MCP port file not found at:" (.getAbsolutePath port-file))
          (println "Please start the Calva MCP socket server in VS Code first."))
        (System/exit 1))
      (if-let [port (get-port-from-file port-file)]
        (do
          (binding [*out* *err*]
            (println "Connecting to Calva MCP socket server on port" port "..."))
          (try
            (with-open [socket (connect-socket "127.0.0.1" port connect-timeout-ms read-timeout-ms)
                        socket-in (.getInputStream socket)
                        socket-out (.getOutputStream socket)
                        stdin System/in
                        stdout System/out]
              (binding [*out* *err*]
                (println "Connected! Bridging stdin/stdout to Calva MCP socket server."))
              (let [t1 (future (pipe stdin socket-out))
                    t2 (future (pipe socket-in stdout))]
                ;; Wait for both threads to complete (e.g. if one connection closes)
                @t1
                @t2))
            (catch Exception e
              (binding [*out* *err*]
                (println "Connection error:" (.getMessage e)))
              (System/exit 1))))
        (do
          (binding [*out* *err*]
            (println "Error: Failed to parse port number from:" (.getAbsolutePath port-file)))
          (System/exit 1))))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
