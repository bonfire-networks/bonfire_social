defmodule Bonfire.Social.Import.Source do
  @moduledoc """
  Where an account import's data comes from, such as an archive zip. A source only reads its data, everything after that is shared by `Bonfire.Social.Import.import_staged/3`.

  Staging is cheap: it checks the input and lists what it offers, with counts, so the person can pick. Materializing returns the picked items, the lists as plain identifiers in memory and the outbox, actor and media on disk in the staged dir.
  """

  @typedoc "One thing a source offers. `key` is an atom for an importable item, since it maps to an import type, and the file name for one that can't be imported."
  @type item :: %{
          key: atom() | String.t(),
          label: String.t(),
          count: non_neg_integer() | nil,
          importable?: boolean(),
          reason: String.t() | nil
        }

  @typedoc "What `stage/1` returns, held by the caller (eg. in a LiveView's assigns) until the import."
  @type staged :: %{
          required(:source) => module(),
          required(:dir) => String.t(),
          required(:items) => [item()],
          optional(atom()) => any()
        }

  @typedoc "The chosen items: lists of identifiers by key, and paths in the staged dir."
  @type materialized :: %{
          lists: %{optional(atom()) => list()},
          outbox: map() | nil,
          actor: map() | nil,
          media_dir: String.t() | nil
        }

  @callback stage(input :: any()) :: {:ok, staged()} | {:error, any()}
  @callback materialize(staged(), keys :: [atom()]) :: {:ok, materialized()} | {:error, any()}
end
