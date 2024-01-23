defmodule Bonfire.Social.Acts.PostContents do
  alias Bonfire.Common.Utils
  # alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

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
        warn(current_user, "Skipping due to current_user")
        epic

      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic

      changeset.action not in [:insert, :upsert, :delete] ->
        maybe_debug(
          epic,
          act,
          changeset.action,
          "Skipping, no matching action on changeset"
        )

        epic

      changeset.action in [:insert, :upsert] ->
        boundary = epic.assigns.options[:boundary]
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns.options, attrs_key, %{})

        if attrs != %{} do
          maybe_debug(epic, act, "Casting post contents")

          changeset
          |> Bonfire.Social.PostContents.cast(attrs, current_user, boundary, epic.assigns.options)
          |> Epic.assign(epic, on, ...)
          |> assign_meta(act, on, :mentions)
          |> assign_meta(act, on, :hashtags)
          |> assign_meta(act, on, :urls)
          |> assign_text(on)
        else
          warn(attrs_key, "Skipping due to empty attrs on key:")
        end

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

  defp assign_text(epic, on, meta_key \\ :text) do
    name = Utils.e(epic.assigns[on], :changes, :post_content, :changes, :name, nil)
    summary = Utils.e(epic.assigns[on], :changes, :post_content, :changes, :summary, nil)
    html_body = Utils.e(epic.assigns[on], :changes, :post_content, :changes, :html_body, nil)

    Epic.assign(epic, meta_key, "#{name} #{summary} #{html_body}")
  end
end
