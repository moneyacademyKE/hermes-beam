(defn port-free? [port]
  (try
    (with-open [s (java.net.ServerSocket. port)]
      true)
    (catch java.net.BindException _ false)))

(defn find-free-port [start end]
  (loop [port start]
    (if (> port end)
      nil
      (if (port-free? port)
        port
        (recur (inc port))))))

(defn write-port-to-file [port filename]
  (spit filename (str port)))

(let [free-port (find-free-port 5001 65535)]
  (when free-port
    (write-port-to-file free-port "port.txt")))