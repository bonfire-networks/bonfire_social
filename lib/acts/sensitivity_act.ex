defmodule Bonfire.Social.Acts.Sensitivity do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that marks the sensitivity level of a object (eg. post) or changeset.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `current_user` - self explanatory
  """

  # alias Bonfire.Data.Social.Sensitive
  alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Common.Utils
  alias Bonfire.Social.Objects
  alias Ecto.Changeset
  # alias Needle.Changesets
  import Epics
  import Untangle
  use Bonfire.Common.E
  use Arrows
  # alias Bonfire.Common
  # alias Common.Types

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "Skipping due to `on` option")
        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "Skipping due to missing current_user")
        epic

      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        warn(changeset, "Skipping :#{on} due to missing changeset")
        epic

      changeset.action == :insert ->
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})

        # || e(changeset, :changes, :post_content, :changes, :summary, nil) || e(attrs, :post_content, :summary, nil) || e(attrs, :summary, nil)
        sensitive =
          e(attrs, :sensitive, nil)

        Objects.cast_sensitivity(changeset, sensitive)
        |> Epic.assign(epic, on, ...)

      changeset.action == :delete ->
        # TODO: deletion
        epic

      true ->
        maybe_debug(
          epic,
          act,
          changeset.action,
          "Skipping, no matching action on changeset"
        )

        epic
    end
  end
end
