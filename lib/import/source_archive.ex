defmodule Bonfire.Social.Import.Source.Archive do
  @moduledoc """
  An account archive zip as an import source: Bonfire's own export, or Mastodon's. One name table covers both, since their file names don't collide (`likes.csv` is Bonfire's, `likes.json` Mastodon's).

  The zip comes from the person uploading it, so every entry name is checked before anything is read, and only the entries the import needs are ever extracted, into the staged dir.
  """
  @behaviour Bonfire.Social.Import.Source

  use Bonfire.Common.E
  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Untangle

  alias Bonfire.Social.Import

  # the lists, by file name: `{key, format}`, where a format says how the file holds its identifiers
  @lists %{
    "following.csv" => {:following, :csv_with_header},
    "requests.csv" => {:requests, :csv_with_header},
    "ghosted.csv" => {:ghosted, :csv_with_header},
    "silenced.csv" => {:silenced, :csv_with_header},
    "bookmarks.csv" => {:bookmarks, :csv},
    "likes.csv" => {:likes, :csv},
    "boosts.csv" => {:boosts, :csv},
    "blocked.csv" => {:blocked, :csv},
    "circles.csv" => {:circles, :csv_pairs},
    "likes.json" => {:likes, :collection},
    "bookmarks.json" => {:bookmarks, :collection}
  }

  @outbox "outbox.json"
  @actor "actor.json"

  # files an archive can hold that we don't import, keyed by their own name since nothing dispatches on them
  @not_importable ["followers.csv", "posts.csv", "messages.csv", "keys.asc"]

  @known Map.keys(@lists) ++ [@outbox, @actor] ++ @not_importable

  @impl true
  def stage(zip_path) when is_binary(zip_path) do
    with {:ok, entries} <- table(zip_path),
         :ok <- check_entries(entries),
         names = Enum.map(entries, &elem(&1, 0)),
         true <-
           Enum.any?(names, &(&1 in @known)) ||
             {:error, l("This archive has nothing we know how to import")},
         {:ok, dir} <- make_dir(),
         zip = Path.join(dir, "archive.zip"),
         :ok <- File.cp(zip_path, zip),
         {:ok, data} <- read_entries(zip, Enum.filter(names, &data_file?/1)) do
      Import.enqueue_archive_cleanup(dir)

      {:ok,
       %{
         source: __MODULE__,
         dir: dir,
         zip: zip,
         items: items(names, data),
         media: Enum.filter(names, &media?/1),
         profile_media:
           Enum.filter(names, &profile_media?/1) ++
             actor_media_names(decode(data[@actor]), names)
       }}
    else
      {:error, _} = error -> error
      other -> error(other, l("Could not read this archive"))
    end
  end

  @impl true
  def materialize(%{zip: zip, dir: dir, items: items} = staged, keys) do
    present = Map.new(items, &{&1.key, &1})

    list_files =
      for {name, {key, format}} <- @lists,
          key in keys,
          present[key],
          into: %{},
          do: {name, {key, format}}

    with {:ok, data} <-
           read_entries(
             zip,
             Map.keys(list_files) ++
               if(:posts in keys, do: [@outbox], else: []) ++
               if(:posts in keys or :profile in keys, do: [@actor], else: [])
           ),
         {:ok, media_dir} <-
           maybe_extract(zip, dir, if(:posts in keys, do: staged.media, else: [])),
         {:ok, profile_dir} <-
           maybe_extract(zip, dir, if(:profile in keys, do: staged.profile_media, else: [])) do
      lists =
        Enum.reduce(list_files, %{}, fn {name, {key, format}}, acc ->
          identifiers = parse(format, data[name])
          Map.update(acc, key, identifiers, &(&1 ++ identifiers))
        end)

      {:ok,
       %{
         lists: lists,
         outbox: decode(data[@outbox]),
         actor: decode(data[@actor]),
         media_dir: media_dir,
         profile_dir: profile_dir
       }}
    end
  end

  defp table(zip_path) do
    case :zip.table(String.to_charlist(zip_path)) do
      {:ok, table} ->
        entries =
          for {:zip_file, name, info, _comment, _offset, _comp_size} <- table,
              # a directory is only a prefix of the names under it
              not String.ends_with?(to_string(name), "/"),
              do: {to_string(name), elem(info, 1)}

        {:ok, entries}

      _ ->
        {:error, l("This is not a zip archive")}
    end
  end

  # every name must stay inside the staged dir once extracted, and the whole has to fit the limits, before anything is read
  defp check_entries(entries) do
    names = Enum.map(entries, &elem(&1, 0))

    cond do
      Enum.any?(names, &(Path.safe_relative(&1) == :error)) ->
        {:error, l("This archive has a file that would be written outside its folder")}

      length(names) != length(Enum.uniq(names)) ->
        {:error, l("This archive has the same file twice")}

      # defaults as in the runtime config, where `IMPORT_ARCHIVE_MAX_ENTRIES` and `IMPORT_ARCHIVE_LIMIT` set them
      length(names) > (Config.get([Import, :max_archive_entries]) || 100_000) ->
        {:error, l("This archive has too many files")}

      Enum.sum(Enum.map(entries, &elem(&1, 1))) >
          (Config.get([Import, :max_archive_size]) || 5_000_000_000) ->
        {:error, l("This archive is too big")}

      true ->
        :ok
    end
  end

  defp make_dir do
    dir =
      Path.join(
        Config.get([Import, :archive_dir], System.tmp_dir!()),
        "import-" <> Needle.UID.generate()
      )

    with :ok <- File.mkdir_p(dir), do: {:ok, dir}
  end

  defp read_entries(_zip, []), do: {:ok, %{}}

  defp read_entries(zip, names) do
    case :zip.extract(String.to_charlist(zip), [
           :memory,
           {:file_list, Enum.map(names, &String.to_charlist/1)}
         ]) do
      {:ok, files} -> {:ok, Map.new(files, fn {name, data} -> {to_string(name), data} end)}
      e -> error(e, l("Could not read this archive"))
    end
  end

  defp maybe_extract(_zip, _dir, []), do: {:ok, nil}

  defp maybe_extract(zip, dir, names) do
    with {:ok, paths} <-
           :zip.extract(String.to_charlist(zip), [
             {:file_list, Enum.map(names, &String.to_charlist/1)},
             {:cwd, String.to_charlist(dir)}
           ]) do
      # only regular files are kept, so a link inside the zip can't point the importer at another file on our disk
      for path <- paths, path = to_string(path) do
        case File.lstat(path) do
          {:ok, %{type: :regular}} -> :ok
          _ -> File.rm_rf(path)
        end
      end

      {:ok, dir}
    else
      e -> error(e, l("Could not extract the archive's files"))
    end
  end

  defp items(names, data) do
    lists =
      for {name, {key, format}} <- @lists, name in names do
        count = length(parse(format, data[name]))

        # an empty file is shown greyed with why, rather than as a box that would import nothing
        %{
          key: key,
          label: list_label(key),
          count: count,
          importable?: count > 0,
          reason: if(count == 0, do: l("Nothing to import in it"))
        }
      end
      # a key from two files (only possible with a mixed archive) is offered once
      |> Enum.uniq_by(& &1.key)

    posts =
      if @outbox in names do
        media = Enum.count(names, &media?/1)
        count = data[@outbox] |> decode() |> outbox_items() |> length()

        [
          %{
            key: :posts,
            # everything in the outbox, posts and boosts alike, hence "objects"
            label: l("Content"),
            detail:
              Enum.join(
                [lp("%{count} object", "%{count} objects", count, count: count)] ++
                  if(media > 0,
                    do: [
                      lp("with %{count} media file", "with %{count} media files", media,
                        count: media
                      )
                    ],
                    else: []
                  ),
                ", "
              ),
            count: count,
            importable?: true,
            reason: nil
          }
        ]
      else
        []
      end

    profile =
      if @actor in names,
        # no count: there is one profile, and "Profile (1)" says nothing
        do: [
          %{
            key: :profile,
            label:
              l("Profile: bio, location, avatar and banner (only if they are currently empty)"),
            count: nil,
            importable?: true,
            reason: nil
          }
        ],
        else: []

    skipped =
      for name <- @not_importable, name in names do
        %{
          key: name,
          label: name,
          count: nil,
          importable?: false,
          reason: not_importable_reason(name)
        }
      end

    posts ++ lists ++ profile ++ skipped
  end

  # Bonfire's export ends its list with an empty item, which isn't a post
  defp outbox_items(%{"orderedItems" => items}) when is_list(items),
    do: Enum.filter(items, &(is_map(&1) and map_size(&1) > 0))

  defp outbox_items(_), do: []

  defp parse(_format, nil), do: []

  # an export with nothing in that list has only its header row, which the one-line fallback of `parse_list/2` (for an uploaded plain text file) would read as a handle
  defp parse(:csv_with_header, csv) do
    if csv |> String.trim() |> String.contains?("\n"),
      do: Import.parse_list(csv, true),
      else: []
  end

  defp parse(:csv, csv), do: Import.parse_list(csv, false)
  defp parse(:csv_pairs, csv), do: Import.parse_pairs(csv, false)

  defp parse(:collection, json) do
    case decode(json) do
      %{"orderedItems" => items} when is_list(items) ->
        for item <- items,
            id = (is_binary(item) && item) || e(item, "id", nil),
            is_binary(id),
            do: id

      _ ->
        []
    end
  end

  defp decode(nil), do: nil

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, data} -> data
      _ -> nil
    end
  end

  defp data_file?(name), do: name in @known and name not in ["keys.asc"]

  defp profile_media?(name), do: Path.rootname(name) in ["avatar", "header"]

  # Bonfire's archive keeps the avatar and banner among its uploads, named by the URL `actor.json` gives them: at `host/path`, or at `path`
  defp actor_media_names(%{} = actor, names) do
    for field <- ["icon", "image"],
        url = e(actor, field, "url", nil),
        is_binary(url),
        uri = URI.parse(url),
        path = String.trim_leading(uri.path || "", "/"),
        name <- Enum.reject([uri.host && Path.join(uri.host, path), path], &is_nil/1),
        name in names,
        uniq: true,
        do: name
  end

  defp actor_media_names(_actor, _names), do: []

  defp media?(name), do: name not in @known and not profile_media?(name)

  defp list_label(:following), do: l("Profiles you follow")
  defp list_label(:requests), do: l("Follow requests you sent")
  defp list_label(:ghosted), do: l("Ghosted profiles")
  defp list_label(:silenced), do: l("Silenced profiles")
  defp list_label(:blocked), do: l("Blocked profiles")
  defp list_label(:bookmarks), do: l("Bookmarks")
  defp list_label(:likes), do: l("Likes")
  defp list_label(:boosts), do: l("Boosts")
  defp list_label(:circles), do: l("Circles and their members")

  defp not_importable_reason("followers.csv"),
    do: l("Followers have to follow you again from their own account")

  defp not_importable_reason("posts.csv"), do: l("Posts are imported from the outbox")
  defp not_importable_reason("messages.csv"), do: l("Messages can't be imported")

  defp not_importable_reason("keys.asc"),
    do: l("Your keys belong to the old account, moving it uses them there")
end
