defmodule Bonfire.Social.Acts.PostContents do

  alias Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.PostContents
  alias Ecto.Changeset
  import Bonfire.Epics
  import Untangle, only: [warn: 2]
  use Arrows

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = epic.assigns.options[:current_user]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "Skipping due to `on` option")
        epic
      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "Skipping due to current_user")
        epic
      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic
      changeset.action not in [:insert, :delete] ->
        maybe_debug(epic, act, changeset.action, "Skipping, no matching action on changeset")
        epic
      changeset.action == :insert ->
        boundary = epic.assigns.options[:boundary]
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns.options, attrs_key, %{})
        maybe_debug(epic, act, "Casting post contents")
        changeset
        |> PostContents.cast(attrs, current_user, boundary)
        |> Epic.assign(epic, on, ...)
        |> assign_meta(act, on, :mentions)
        |> assign_meta(act, on, :urls)
      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

  defp assign_meta(epic, act, on, meta_key) do
    data = Utils.e(epic.assigns[on], :changes, :post_content, :changes, meta_key, [])
    smart(epic, act, data, "found #{meta_key}")
    Epic.assign(epic, meta_key, data)
  end

end
