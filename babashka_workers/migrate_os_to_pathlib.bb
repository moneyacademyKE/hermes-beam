(defn migrate-os-to-pathlib [dir] 
  (let [python-files (find-python-files dir)] 
    (doseq [file python-files] 
      (let [content (slurp file) 
            migrated-content (str/replace content #"os.path" "pathlib.Path")] 
        (spit file migrated-content))))) 

(migrate-os-to-pathlib ".")