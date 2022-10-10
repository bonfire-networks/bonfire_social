defmodule Bonfire.Social.Acts.Files do
  @moduledoc """
  Saves uploaded files as attachments to the post.

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
    * `:uploads` - epic options key to find the uploaded media objects at, default: `:uploaded_media`.
  """
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.Epic
  alias Bonfire.Common.Repo
  # alias Bonfire.Files
  alias Ecto.Changeset
  alias Pointers.Changesets
  import Bonfire.Social.Integration, only: [repo: 0]
  import Epics
  import Untangle, only: [error: 2, warn: 1]

  def run(epic, act) do
    cond do
      epic.errors != [] ->
        Epics.smart(epic, act, epic.errors, "Skipping due to epic errors")
        epic

      true ->
        on = Keyword.fetch!(act.options, :on)
        changeset = epic.assigns[on]
        # current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        uploads_key = Keyword.get(act.options, :uploads, :uploaded_media)

        uploaded_media = e(attrs, uploads_key, []) ++ e(epic.assigns, uploads_key, [])

        case changeset do
          %Changeset{valid?: true} = changeset ->
            smart(epic, act, uploaded_media, "upload media")

            uploaded_media
            |> Enum.map(&%{media: &1})
            |> Changesets.put_assoc(changeset, :files, ...)
            |> Epic.assign(epic, on, ...)

          %Changeset{valid?: false} = changeset ->
            maybe_debug(epic, act, changeset, "invalid changeset")
            epic

          other ->
            maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
            epic
        end
    end
  end
end