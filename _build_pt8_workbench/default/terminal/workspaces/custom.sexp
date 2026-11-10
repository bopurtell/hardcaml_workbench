; A custom-only session, including duplicate kinds with independent leaf/presentation keys.
; Geometry is requested size, not arbitrary terminal free placement. Fit uses the tree.
((version 1)
 (id my-investigation)
 (definitions
  (((key compare)
    (template
     ((version 1) (name "Compare runs")
      (views
       (((kind run-selector) (hidden false)
         (geometry ((x 0) (y 0) (width 80) (height 7))))
        ((kind synthesis) (hidden false)
         (geometry ((x 0) (y 0) (width 40) (height 15))))
        ((kind synthesis) (hidden false)
         (geometry ((x 0) (y 0) (width 40) (height 15))))))))
    (tiles
     (((key choose) (presentation (((visible_rows (4))))))
      ((key left) (presentation (((compact_summary (true)) (hints (false))))))
      ((key right) (presentation (((title (true)) (padding (1))))))))
    (layout
     ((Stack
       ((Leaf (tile choose) (min_width 24) (min_height 7) (weight 0))
        (Columns
         ((Leaf (tile right) (min_width 24) (min_height 10) (weight 1))
          (Leaf (tile left) (min_width 24) (min_height 10) (weight 1)))))))))))
 (windows
  (((key desk) (name Investigation)
    (workspaces
     (((key compare) (name "My comparison") (definition (Custom compare)))))))))
