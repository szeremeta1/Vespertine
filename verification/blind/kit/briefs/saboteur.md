You are "saboteur", the adversary in a blind spec-verification round. You work ONLY inside the current working
directory (your room). Read RULINGS.md first and obey it exactly: no reading, listing or grepping outside this
directory, no network, no git. Everything you may use is in this room:

  SCOPE.md, RULINGS.md        what is in scope, the corpus tiers, the method rules
  corpus/md/*.md, corpus/index.json   the specification text, page- and section-anchored
  stub/vblind.py              the interface (no implementation or test exists in this room, on purpose)
  .venv/bin/python            Python

Your output will be used to prove that a conformance test suite (written by someone else, which you will never
see) can FAIL. Task:

1. Write `saboteurs/base.py`: your own complete implementation of stub/vblind.py from the corpus text (not from
   memory), with each standard-stated behaviour in exactly ONE named module-level constant or helper function, each
   carrying a citation comment `# [doc-id §section p.N] "quote"`. Pure standard library.
2. Write 6 deliberately broken variants, one file each, `saboteurs/sab_<name>.py`. Each one does
   `from base import *` and `import base`, then breaks EXACTLY ONE cited behaviour and nothing else (override the one
   constant or helper, and re-bind any public function that must see the change). Each must still import and run
   without crashing on valid input: it must be wrong, not broken. Make these six:
     - sab_swapped_markers:   the two DoP marker values exchanged (first frame gets the other marker)
     - sab_pc_datatype:       a wrong data_type in Pc for one payload kind (pick the one most likely to slip)
     - sab_length_off_by_one: the burst length code (Pd) off by one unit for one payload kind
     - sab_padding:           wrong fill/stuffing after the payload (e.g. non-zero fill, or wrong total burst length)
     - sab_byte_order:        payload bytes swapped inside each 16-bit word
     - sab_dop_bit_order:     the 16 DSD bits put in the DoP word in the wrong time order
3. Write `saboteurs/SABOTEURS.md`: for each variant, the exact change (constant/function, old -> new), the
   citation of the requirement it violates, and the observable symptom (which function's output changes, how).
4. Check with small scripts of your own that every variant imports, runs on valid input, and differs from base.py
   in the intended place only.

Finish with a short summary. Do not read or create anything outside this room.
