# Used by "mix format"
[
  # stream_data: keeps the house `check all ... do` / `gen all ... do`
  # property style formatter-legal (locals_without_parens).
  import_deps: [:stream_data],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
