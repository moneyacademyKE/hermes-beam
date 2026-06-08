(ns worker
  (:require [clojure.core.async :as async]
            [cheshire.core :as json]
            [babashka.http-client :as http])
  (:import [java.net UnixDomainSocketAddress StandardProtocolFamily]
           [java.nio.channels SocketChannel]
           [java.nio ByteBuffer]))

(defn connect-uds [path]
  (let [addr (UnixDomainSocketAddress/of path)
        channel (SocketChannel/open StandardProtocolFamily/UNIX)]
    (.connect channel addr)
    channel))

(defn send-msg [channel msg]
  (let [bytes (.getBytes msg "UTF-8")
        buf (ByteBuffer/wrap bytes)]
    (.write channel buf)))

(defn send-telemetry [channel status]
  (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                           :method "telemetry"
                                           :params {:status status
                                                    :memory (.freeMemory (Runtime/getRuntime))}})))

(defn handle-task [channel payload]
  (try
    (let [{:keys [url model messages api_key]} payload
          response (http/post url
                              {:headers {"Authorization" (str "Bearer " api_key)
                                         "Content-Type" "application/json"}
                               :body (json/generate-string {:model model
                                                            :messages messages})})
          result (json/parse-string (:body response) true)]
      (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                               :method "task_result"
                                               :params {:result result}})))
    (catch Exception e
      (send-msg channel (json/generate-string {:jsonrpc "2.0"
                                               :error {:message (.getMessage e)}})))))

(defn read-loop [channel]
  (let [buf (ByteBuffer/allocate 65536)]
    (loop []
      (.clear buf)
      (let [bytes-read (.read channel buf)]
        (when (pos? bytes-read)
          (.flip buf)
          (let [bytes (byte-array (.remaining buf))
                _ (.get buf bytes)
                msg-str (String. bytes "UTF-8")]
            (try
              (let [msg (json/parse-string msg-str true)]
                (when (= (:method msg) "execute_task")
                  (handle-task channel (:params msg))))
              (catch Exception e
                (println "Error parsing msg:" msg-str)))))
        (when-not (= bytes-read -1)
          (recur))))))

(defn telemetry-loop [channel]
  (async/go-loop []
    (async/<! (async/timeout 5000))
    (send-telemetry channel "running")
    (recur)))

(defn -main [& args]
  (let [path (first args)
        channel (connect-uds path)]
    (println "Worker started, connected to:" path)
    (send-msg channel "{\"jsonrpc\":\"2.0\",\"method\":\"init\",\"params\":{\"status\":\"ready\"}}")
    (telemetry-loop channel)
    (read-loop channel)))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
