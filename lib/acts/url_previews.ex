defmodule Bonfire.Social.Acts.URLPreviews do
  @moduledoc """
  Fetch and save metadata of URLs

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
    * `:uploads` - epic options key to find the uploaded media objects at, default: `:urls`.
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
        current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
        # attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        # attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        urls_key = Keyword.get(act.options, :urls, :urls)
        media_key = Keyword.get(act.options, :medias, :uploaded_media)

        case changeset do
          %Changeset{valid?: true} = changeset ->
            smart(epic, act, changeset, "valid changeset")
            urls = Map.get(epic.assigns, urls_key, [])

            urls
            |> smart(epic, act, ..., "URLs")
            |> Enum.map(&maybe_fetch_and_save(current_user, &1))
            |> maybe_debug(epic, act, ..., "metadata")
            |> Epic.assign(epic, media_key, ...)

          %Changeset{valid?: false} = changeset ->
            maybe_debug(epic, act, changeset, "invalid changeset")
            epic

          other ->
            error(other, "not a changeset")
            Epic.add_error(epic, act, {:expected_changeset, other})
        end
    end
  end

  def maybe_fetch_and_save(current_user, url) do
    with {:ok, meta} <- Furlex.unfurl(url),
         media_type <-
           e(meta, :oembed, "type", nil) || e(meta, :facebook, "og:type", nil),
         {:ok, media} <-
           Bonfire.Files.Media.insert(
             current_user,
             url,
             %{media_type: media_type, size: 0},
             %{metadata: Map.from_struct(meta)}
           ) do
      # |> debug
      media
    else
      _ ->
        nil
    end
  end

  defp assign_medias(epic, act, on, meta_key, data) do
    smart(epic, act, data, "found #{meta_key}")
    Epic.assign(epic, meta_key, data)
  end
end
