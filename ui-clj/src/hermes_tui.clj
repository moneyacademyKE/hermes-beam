(ns hermes-tui
  (:require
   [babashka.fs :as fs]
   [babashka.process :as proc]
   [cheshire.core :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [clojure.core.async :as a]
   [charm.core :as charm]
   [charm.style.core :as style]
   [charm.components.text-input :as text-input]
   [charm.components.spinner :as spinner]))

;; Colors
(def color-brand (style/rgb 139 92 246)) ;; Vibrant violet
(def color-accent (style/rgb 6 182 212)) ;; Cyan
(def color-success (style/rgb 16 185 129)) ;; Green
(def color-error (style/rgb 239 68 68)) ;; Red
(def color-text (style/rgb 243 244 246)) ;; Light gray
(def color-dim (style/rgb 156 163 175)) ;; Gray
(def color-bg-header (style/rgb 31 41 55)) ;; Dark gray

(defn styled-brand [text] (style/styled text :fg color-brand :bold true))
(defn styled-accent [text] (style/styled text :fg color-accent))
(defn styled-success [text] (style/styled text :fg color-success))
(defn styled-error [text] (style/styled text :fg color-error))
(defn styled-dim [text] (style/styled text :fg color-dim))

(defn find-in-path [cmd]
  (let [paths (str/split (System/getenv "PATH") (re-pattern (System/getProperty "path.separator")))]
    (some (fn [p]
            (let [f (fs/file p cmd)]
              (when (and (fs/exists? f) (not (fs/directory? f)))
                (str f))))
          paths)))

(defn resolve-python [project-root]
  (let [env-py (or (System/getenv "HERMES_PYTHON")
                   (System/getenv "PYTHON"))]
    (if (and env-py (fs/exists? env-py))
      env-py
      (let [venv (System/getenv "VIRTUAL_ENV")
            candidates (remove nil?
                               [(when venv (str (fs/path venv "bin" "python")))
                                (when venv (str (fs/path venv "Scripts" "python.exe")))
                                (str (fs/path project-root ".venv" "bin" "python"))
                                (str (fs/path project-root ".venv" "bin" "python3"))
                                (str (fs/path project-root "venv" "bin" "python"))
                                (str (fs/path project-root "venv" "bin" "python3"))])]
        (or (first (filter fs/exists? candidates))
            "python3")))))

(defn resolve-gateway-command [project-root]
  (let [gleam-path (and (fs/exists? (fs/path project-root "gleam.toml"))
                        (find-in-path "gleam"))]
    (if gleam-path
      ["gleam" "run" "--" "--tui"]
      (let [python (resolve-python project-root)]
        [python "-m" "tui_gateway.entry"]))))

(defn write-active-session-file [session-id]
  (when-let [file (System/getenv "HERMES_TUI_ACTIVE_SESSION_FILE")]
    (try
      (spit file (json/generate-string {:session_id session-id}))
      (catch Exception _))))

(defn log-debug [& args]
  (when (= (System/getenv "HERMES_CLJ_DEBUG") "1")
    (try
      (with-open [w (io/writer "hermes-clj-debug.log" :append true)]
        (.write w (str (str/join " " args) "\n")))
      (catch Exception _))))

(defn read-chan-cmd [ch]
  (charm/cmd
    (fn []
      (a/<!! ch))))

(defn send-rpc-request [state method params]
  (let [next-id (inc (:rpc-id state))
        req {:jsonrpc "2.0" :method method :params params :id next-id}
        req-str (str (json/generate-string req) "\n")]
    (log-debug "Sending RPC request:" req-str)
    (try
      (.write (:stdin-writer state) req-str)
      (.flush (:stdin-writer state))
      (catch Exception e
        (log-debug "Failed to write RPC request:" e)))
    (assoc state :rpc-id next-id)))

(defn tool-trail-label [name]
  (if (str/blank? name)
    ""
    (->> (str/split name #"_")
         (remove str/blank?)
         (map #(str (str/upper-case (subs % 0 1)) (subs % 1)))
         (str/join " "))))

(defn compact-preview [text max-len]
  (if (str/blank? text)
    ""
    (let [cleaned (-> text
                      (str/replace #"\r?\n" " ")
                      (str/replace #"\s+" " ")
                      (str/trim))]
      (if (> (count cleaned) max-len)
        (str (subs cleaned 0 (- max-len 3)) "...")
        cleaned))))

(defn format-tool-call [name context]
  (let [label (tool-trail-label name)
        preview (compact-preview context 64)]
    (if (str/blank? preview)
      label
      (str label "(\"" preview "\")"))))

(defn build-tool-trail-line [name context error? note duration]
  (let [call-str (format-tool-call name context)
        took (if duration (format " (%.1fs)" (double duration)) "")
        detail (if (seq note) (compact-preview note 72) "")
        sep (if (seq detail) " :: " "")
        status-char (if error? "✗" "✓")]
    (str call-str took sep detail " " status-char)))

(defn to-transcript-messages [rows]
  (loop [remaining rows
         out []
         pending-tools []]
    (if-let [row (first remaining)]
      (let [{:keys [role text name context error note duration]} row]
        (cond
          (= role "tool")
          (recur (rest remaining)
                 out
                 (conj pending-tools (build-tool-trail-line name context error note duration)))

          (or (nil? text) (str/blank? (str text)))
          (recur (rest remaining) out pending-tools)

          (= role "assistant")
          (recur (rest remaining)
                 (conj out {:role role :text text :tools (seq pending-tools)})
                 [])

          (or (= role "user") (= role "system"))
          (recur (rest remaining)
                 (conj out {:role role :text text})
                 [])

          :else
          (recur (rest remaining) out pending-tools)))
      out)))

(defn wrap-line [text width]
  (if (str/blank? text)
    [""]
    (let [words (str/split text #"\s+")]
      (loop [remaining words
             current-line ""
             lines []]
        (if-let [word (first remaining)]
          (let [space (if (empty? current-line) "" " ")
                candidate (str current-line space word)]
            (if (<= (count candidate) width)
              (recur (rest remaining) candidate lines)
              (recur (rest remaining) word (conj lines current-line))))
          (conj lines current-line))))))

(defn wrap-text [text width]
  (if (str/blank? text)
    []
    (->> (str/split-lines text)
         (mapcat #(wrap-line % width)))))

(defn format-message-lines [msg width]
  (let [role (:role msg)
        text (:text msg)
        tools (:tools msg)
        wrap-w (- width 12)]
    (cond
      (= role "user")
      (let [wrapped (wrap-text text wrap-w)
            first-line (str (styled-accent "You:      ") (or (first wrapped) ""))
            other-lines (map #(str "          " %) (rest wrapped))]
        (cons first-line other-lines))

      (= role "assistant")
      (let [wrapped (wrap-text text wrap-w)
            first-line (str (styled-brand "Hermes:   ") (or (first wrapped) ""))
            other-lines (map #(str "          " %) (rest wrapped))
            tool-lines (map #(str "          " (styled-dim %)) tools)]
        (concat [first-line] other-lines tool-lines))

      :else
      (let [wrapped (wrap-text text wrap-w)
            first-line (str (style/styled "System:   " :fg style/yellow :bold true) (or (first wrapped) ""))
            other-lines (map #(str "          " %) (rest wrapped))]
        (cons first-line other-lines)))))

(defn get-all-message-lines [state]
  (let [width (:width state)
        history-lines (mapcat #(format-message-lines % width) (:messages state))
        streaming-lines (if (or (seq (:partial-response state)) (seq (:turn-tool-trail state)))
                          (format-message-lines {:role "assistant" :text (:partial-response state) :tools (:turn-tool-trail state)} width)
                          [])]
    (concat history-lines streaming-lines)))

(defn handle-event [state event-type payload]
  (log-debug "Handling event:" event-type "with payload:" payload)
  (case event-type
    "gateway.ready"
    (if-not (:startup-submitted? state)
      (let [resume-id (System/getenv "HERMES_TUI_RESUME")
            width (:width state)]
        (if-not (str/blank? resume-id)
          (-> state
              (assoc :startup-submitted? true :status "resuming session...")
              (send-rpc-request "session.resume" {:session_id resume-id :cols width}))
          (-> state
              (assoc :startup-submitted? true :status "checking recent sessions...")
              (send-rpc-request "session.most_recent" {}))))
      state)

    "session.info"
    (-> state
        (assoc :model (get payload :model "default")
               :provider (get payload :provider "default")
               :cwd (get payload :cwd (:cwd state))
               :usage (get payload :usage (:usage state))))

    "status.update"
    (assoc state :status (:text payload))

    ("thinking.delta" "reasoning.delta")
    (-> state
        (assoc :status "thinking...")
        (update :thinking-content str (:text payload)))

    "message.start"
    (assoc state :running? true :partial-response "" :thinking-content "" :tool-calls {} :turn-tool-trail [])

    "message.delta"
    (-> state
        (assoc :thinking-content "")
        (update :partial-response str (:text payload)))

    "message.complete"
    (let [msg (:message payload)]
      (write-active-session-file (:session-id state))
      (-> state
          (assoc :running? false :partial-response "" :turn-tool-trail [] :status "ready")
          (update :messages conj (cond-> {:role "assistant" :text (:text msg)}
                                   (:reasoning msg) (assoc :reasoning (:reasoning msg))
                                   (seq (:turn-tool-trail state)) (assoc :tools (:turn-tool-trail state))))))

    "tool.start"
    (assoc-in state [:tool-calls (:id payload)] {:name (:name payload) :title (:title payload) :status :running})

    "tool.complete"
    (let [tool-id (:id payload)
          tool (get-in state [:tool-calls tool-id])
          trail-line (build-tool-trail-line (:name tool) (:result payload) (:error payload) (:note payload) (:duration payload))]
      (-> state
          (update :tool-calls dissoc tool-id)
          (update :turn-tool-trail conj trail-line)))

    "approval.request"
    (assoc state :input-mode :approval :approval-req payload :status "approval needed")

    "clarify.request"
    (assoc state :input-mode :clarify :approval-req payload :status "waiting for input...")

    "sudo.request"
    (assoc state :input-mode :sudo :approval-req payload :status "sudo password needed")

    "secret.request"
    (assoc state :input-mode :secret :approval-req payload :status "secret input needed")

    state))

(defn handle-rpc-response [state id result error]
  (log-debug "Received RPC response for id:" id "result:" result "error:" error)
  (if error
    (assoc state :status (str "error: " (:message error)))
    (cond
      (and (map? result) (contains? result :messages))
      (let [sid (:session_id result)
            msgs (to-transcript-messages (:messages result))
            info (:info result)
            cwd (get info :cwd (:cwd state))
            model (get info :model (:model state))
            provider (get info :provider (:provider state))
            usage (get info :usage (:usage state))]
        (write-active-session-file sid)
        (assoc state
               :session-id sid
               :messages msgs
               :cwd cwd
               :model model
               :provider provider
               :usage usage
               :status "ready"
               :running? false))

      (and (map? result) (contains? result :session_id))
      (let [sid (:session_id result)]
        (if (str/blank? sid)
          (send-rpc-request state "session.create" {:cols (:width state)})
          (send-rpc-request state "session.resume" {:session_id sid :cols (:width state)})))

      (nil? result)
      (send-rpc-request state "session.create" {:cols (:width state)})

      :else
      state)))

(defn handle-key-in-mode [state msg]
  (let [mode (:input-mode state)
        val (text-input/value (:input-state state))]
    (cond
      (= mode :approval)
      (let [k (:key msg)]
        (cond
          (or (= k "y") (= k "Y") (= k "a") (= k "A") (= k "enter"))
          (let [next-state (send-rpc-request state "approval.respond" {:choice "allow" :session_id (:session-id state)})]
            [(assoc next-state :input-mode :text :approval-req nil) nil])

          (or (= k "n") (= k "N") (= k "escape"))
          (let [next-state (send-rpc-request state "approval.respond" {:choice "deny" :session_id (:session-id state)})]
            [(assoc next-state :input-mode :text :approval-req nil) nil])

          :else [state nil]))

      (and (or (= mode :clarify) (= mode :sudo) (= mode :secret))
           (= (:key msg) "enter"))
      (let [req-id (get-in state [:approval-req :request_id])
            next-state (case mode
                         :clarify (send-rpc-request state "clarify.respond" {:answer val :request_id req-id})
                         :sudo    (send-rpc-request state "sudo.respond" {:password val :request_id req-id})
                         :secret  (send-rpc-request state "secret.respond" {:value val :request_id req-id}))]
        [(-> next-state
             (assoc :input-mode :text :approval-req nil)
             (update :input-state text-input/reset))
         nil])

      (and (= mode :text) (= (:key msg) "enter"))
      (if (str/blank? val)
        [state nil]
        (let [full-input (str/trim val)]
          (cond
            ;; Native commands
            (or (= full-input "/quit") (= full-input "/exit"))
            [state charm/quit-cmd]

            (= full-input "/clear")
            [(-> state
                 (assoc :messages [])
                 (update :input-state text-input/reset)) nil]

            ;; Slash command
            (str/starts-with? full-input "/")
            (let [next-state (send-rpc-request state "slash.exec" {:command (subs full-input 1) :session_id (:session-id state)})]
              [(-> next-state
                   (update :input-state text-input/reset)
                   (update :messages conj {:role "system" :text full-input}))
               nil])

            ;; Normal prompt
            :else
            (let [next-state (send-rpc-request state "prompt.submit" {:session_id (:session-id state) :text full-input})]
              [(-> next-state
                   (update :input-state text-input/reset)
                   (update :messages conj {:role "user" :text full-input})
                   (assoc :running? true :status "running..."))
               nil]))))

      :else
      (let [[new-input cmd] (text-input/text-input-update (:input-state state) msg)]
        [(assoc state :input-state new-input) cmd]))))

(defn update-fn [state msg]
  (log-debug "Received update message type:" (:type msg) "msg:" msg)
  (cond
    (= (:type msg) :backend-line)
    (let [line (:line msg)
          parsed (try (json/parse-string line true) (catch Exception _ nil))
          method (:method parsed)
          params (:params parsed)
          event-type (:type params)
          payload (:payload params)]
      (cond
        (= method "event")
        (let [next-state (handle-event state event-type payload)]
          [next-state (read-chan-cmd (:events-chan next-state))])

        (= method "hermes.broadcast")
        (let [next-state (assoc state :status (str "Broadcast: " (get payload :attribute "")))]
          [next-state (read-chan-cmd (:events-chan next-state))])

        (and (contains? parsed :id) (nil? method))
        (let [next-state (handle-rpc-response state (:id parsed) (:result parsed) (:error parsed))]
          [next-state (read-chan-cmd (:events-chan next-state))])

        :else
        [state (read-chan-cmd (:events-chan state))]))

    (= (:type msg) :backend-eof)
    [state charm/quit-cmd]

    (= (:type msg) :backend-error)
    [state charm/quit-cmd]

    (= (:type msg) :window-size)
    [(assoc state :width (:width msg) :height (:height msg)) nil]

    (= (:type msg) :spinner-tick)
    (let [[new-spinner cmd] (spinner/spinner-update (:spinner-state state) msg)]
      [(assoc state :spinner-state new-spinner) cmd])

    :else
    (handle-key-in-mode state msg)))

(defn header-view [state]
  (let [sid (or (:session-id state) "initializing...")
        model (:model state)
        usage (:usage state)
        in-tokens (get usage :input_tokens 0)
        out-tokens (get usage :output_tokens 0)
        header-text (str " ⚡ HERMES  |  Session: " sid "  |  Model: " model "  |  Tokens: " in-tokens " / " out-tokens)]
    (style/render (style/style :fg color-text :bg color-bg-header :bold true :width (:width state)) header-text)))

(defn status-view [state]
  (if (:running? state)
    (let [spinner-str (spinner/spinner-view (:spinner-state state))
          active-tools (vals (:tool-calls state))
          tool-names (str/join ", " (map :name active-tools))
          tool-suffix (if (seq tool-names) (str " (running: " tool-names ")") "")]
      (str spinner-str " " (styled-brand (or (:status state) "thinking...")) tool-suffix))
    (str (styled-success "●") " " (styled-dim (or (:status state) "ready")))))

(defn approval-view [state]
  (let [req (:approval-req state)
        cmd (:command req)
        desc (or (:description req) "dangerous command")]
    (style/render
     (style/style :border style/rounded-border :border-fg color-brand :padding 1 :margin 1 :width (:width state))
     (str (style/styled "⚠️ APPROVAL REQUIRED" :fg color-error :bold true) "\n\n"
          "Description: " desc "\n"
          "Command:     " (style/styled cmd :fg color-accent :bold true) "\n\n"
          "Allow this action? [" (style/styled "y" :fg color-success :bold true) "es / " (style/styled "n" :fg color-error :bold true) "o]"))))

(defn clarify-view [state]
  (let [req (:approval-req state)
        q (:question req)
        choices (:choices req)]
    (style/render
     (style/style :border style/rounded-border :border-fg color-accent :padding 1 :margin 1 :width (:width state))
     (str (style/styled "❓ QUESTION" :fg color-accent :bold true) "\n\n"
          q "\n"
          (if (seq choices)
            (str "\nChoices:\n" (str/join "\n" (map-indexed #(str "  " (inc %1) ". " %2) choices)))
            "")))))

(defn sudo-secret-view [state]
  (let [req (:approval-req state)
        prompt-text (or (:prompt req) (if (= (:input-mode state) :sudo) "Enter sudo password:" "Enter secret value:"))]
    (style/render
     (style/style :border style/rounded-border :border-fg color-error :padding 1 :margin 1 :width (:width state))
     (str (style/styled "🔐 SECURITY INPUT" :fg color-error :bold true) "\n\n"
          prompt-text))))

(defn get-input-view [state]
  (let [mode (:input-mode state)
        input-comp (:input-state state)
        configured-input (case mode
                           :sudo (assoc input-comp :echo-mode :password)
                           :secret (assoc input-comp :echo-mode :password)
                           input-comp)]
    (text-input/text-input-view configured-input)))

(defn view-fn [state]
  (let [header (header-view state)
        all-lines (get-all-message-lines state)
        overlay-lines (case (:input-mode state)
                        :approval (count (str/split-lines (approval-view state)))
                        :clarify (count (str/split-lines (clarify-view state)))
                        (:sudo :secret) (count (str/split-lines (sudo-secret-view state)))
                        0)
        reserved-height (+ 1 ;; header
                           1 ;; status line
                           1 ;; space
                           1 ;; input prompt
                           overlay-lines)
        transcript-height (max 5 (- (:height state) reserved-height))
        visible-lines (take-last transcript-height all-lines)
        transcript-str (str/join "\n" visible-lines)
        status-str (status-view state)
        overlay-str (case (:input-mode state)
                      :approval (approval-view state)
                      :clarify (clarify-view state)
                      (:sudo :secret) (sudo-secret-view state)
                      "")
        input-str (get-input-view state)]
    (str/join "\n"
              (remove str/blank?
                      [header
                       transcript-str
                       ""
                       status-str
                       overlay-str
                       input-str]))))

(def hermes-app
  {:init
   (fn []
     (let [project-root (fs/canonicalize (fs/path "." ".."))
           cmd-args (resolve-gateway-command project-root)
           _ (log-debug "Spawning gateway process with command:" cmd-args)
           gateway-proc (apply proc/process {:dir (str project-root) :out :stream :in :stream :err :stream} cmd-args)
           stdin-writer (io/writer (:in gateway-proc))
           stdout-reader (io/reader (:out gateway-proc))
           input-state (-> (text-input/text-input :prompt "> ")
                           (text-input/focus))
           spin (spinner/spinner :dots)
           [spin-state spin-cmd] (spinner/spinner-init spin)
           events-chan (a/chan 100)]
       
       (a/thread
         (try
           (loop []
             (if-let [line (.readLine stdout-reader)]
               (do
                 (a/>!! events-chan {:type :backend-line :line line})
                 (recur))
               (a/>!! events-chan {:type :backend-eof})))
           (catch Exception e
             (a/>!! events-chan {:type :backend-error :error e}))))
             
       [{:session-id nil
         :messages []
         :partial-response ""
         :thinking-content ""
         :tool-calls {}
         :turn-tool-trail []
         :cwd (str project-root)
         :model "default"
         :provider "default"
         :usage {}
         :status "starting gateway..."
         :running? true
         :startup-submitted? false
         :input-mode :text
         :approval-req nil
         :rpc-id 0
         :width 80
         :height 24
         :gateway-proc gateway-proc
         :stdin-writer stdin-writer
         :stdout-reader stdout-reader
         :events-chan events-chan
         :input-state input-state
         :spinner-state spin-state}
        (charm/batch (read-chan-cmd events-chan) spin-cmd)]))
   :update update-fn
   :view view-fn})

(defn -main [& _args]
  (try
    (let [final-state (charm/run hermes-app)]
      (when-let [proc (:gateway-proc final-state)]
        (proc/destroy proc)))
    (catch Exception e
      (println "TUI Error:" (.getMessage e))
      (System/exit 1))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
