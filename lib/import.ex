defmodule Bonfire.Social.Import do
  use Oban.Worker,
    #  TODO: sort out queue vs op
    queue: :import,
    max_attempts: 1

  use Arrows

  alias NimbleCSV.RFC4180, as: CSV

  import Untangle
  # alias Bonfire.Data.Identity.User
  # alias Bonfire.Me.Characters
  use Bonfire.Common.E
  use Bonfire.Common.Localise
  use Bonfire.Common.Settings
  use Bonfire.Common.Config
  use Bonfire.Common.Repo
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Enums
  alias Bonfire.Me.Users
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @doc """
  Import follows, ghosts, silences, or blocks from a CSV file.

  ## Examples

      iex> import_from_csv_file(:following, scope, "path/to/file.csv")

  """
  def import_from_csv_file(:following, scope, path), do: follows_from_csv_file(scope, path)
  def import_from_csv_file(:ghosts, scope, path), do: ghosts_from_csv_file(scope, path)
  def import_from_csv_file(:silences, scope, path), do: silences_from_csv_file(scope, path)
  def import_from_csv_file(:blocks, scope, path), do: blocks_from_csv_file(scope, path)
  def import_from_csv_file(:bookmarks, scope, path), do: bookmarks_from_csv_file(scope, path)
  def import_from_csv_file(:circles, scope, path), do: circles_from_csv_file(scope, path)
  def import_from_csv_file(:likes, scope, path), do: likes_from_csv_file(scope, path)
  def import_from_csv_file(:boosts, scope, path), do: boosts_from_csv_file(scope, path)

  def import_from_csv_file(:outbox = type, scope, path),
    do: import_from_json_file(type, scope, path)

  # TODO: import keyword filters from a Mastodon-style `custom_filters.json` export: each filter's keywords go into the person's keyword lists, `"action": "hide"` into `[:activity_pub, :mrf_keyword, :reject]` and `"warn"` into `[:activity_pub, :mrf_keyword, :warn]`, a keyword with `"whole_word": false` as `*keyword*`. Titles, contexts, expiry and per-post filters are ignored. Parsed and saved in one write, not queued per row

  def import_from_csv_file(_other, _user, _path),
    do: error("Please select a valid type of import")

  @doc """
  Import user's outbox (posts and activities) from a JSON file.

  ## Examples

      iex> import_from_json_file("user_id", "path/to/outbox.json")
      %{imported: 5, boosted: 3, errors: 1}

  """
  def import_from_json_file(type, user, path, opts \\ []) do
    with {:ok, json_content} <- File.read(path),
         {:ok, outbox_data} <- Jason.decode(json_content) do
      import_from_json(type, user, outbox_data, opts)
    else
      error ->
        error(error, "Failed to read or parse JSON file")
    end
  end

  @doc """
  Import user's outbox from parsed JSON data.
  """
  def import_from_json(type, user_id, outbox_data, opts \\ [])

  def import_from_json(:outbox = _type, user, outbox_data, opts) do
    # the outbox's boosts are only queued when asked for, so what's reported as queued is what gets imported
    {boosts, activities} =
      outbox_data
      |> Map.get("orderedItems", [])
      |> Enum.split_with(&(!opts[:include_boosts] and e(&1, "type", nil) == "Announce"))

    # a post addressed to nobody (Mastodon's private mention with no one mentioned, a note to self) comes in visible only to the person importing it, which the report says
    to_nobody = Enum.filter(activities, &addressed_to_nobody?/1)

    op = if(opts[:include_boosts], do: "outbox_import", else: "outbox_creations_import")

    # before the posts, so each finds its author already known rather than each falling back to the service actor
    maybe_create_gone_author(opts[:actor], activities)

    # TODO: should we only save the type and object id in the queue metadata?
    enqueue_many(
      op,
      Enums.id(user),
      activities,
      if(opts[:media_dir], do: %{"media_dir" => opts[:media_dir]}, else: %{})
    )
    |> Map.put(
      :notes,
      for(
        activity <- to_nobody,
        do: %{
          key: e(activity, "object", "id", nil) || e(activity, "id", nil),
          reason: l("Imported, visible only to you")
        }
      )
    )
    |> Map.put(
      :skipped,
      if(boosts != [],
        do: [
          %{
            key: l("Boosts"),
            reason:
              lp(
                "%{count} boost left out, since importing boosts wasn't ticked",
                "%{count} boosts left out, since importing boosts wasn't ticked",
                length(boosts),
                count: length(boosts)
              )
          }
        ],
        else: []
      )
    )
  end

  # only a post that says so: Mastodon writes `"to": []` and `"cc": []`, while a post with no addressing at all is malformed, and fails like any other
  defp addressed_to_nobody?(%{"type" => "Create", "object" => %{} = object} = activity) do
    (Map.has_key?(activity, "to") or Map.has_key?(object, "to")) and
      [activity["to"], activity["cc"], object["to"], object["cc"], object["bto"], object["bcc"]]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.empty?()
  end

  defp addressed_to_nobody?(_), do: false

  # The old account's actor document from an archive (`actor.json`), for when its server no longer answers, eg. the account was deleted after moving. The upload can be forged, so it's only used for the author of the posts it comes with, only when the real one can't be fetched, never with its key (it would let anyone sign as that actor), and it's marked as unverified.
  defp maybe_create_gone_author(%{"id" => id} = actor, activities) when is_binary(id) do
    with true <- Enum.any?(activities, &(e(&1, "object", "attributedTo", nil) == id)),
         {:error, _} <- ActivityPub.Actor.get_cached_or_fetch(ap_id: id) do
      actor
      |> Map.delete("publicKey")
      |> ActivityPub.Actor.create_or_update_actor_from_object(
        already_fetched: true,
        authenticated: :unverified
      )
      |> debug("created the gone author from the archive")
    end
  end

  defp maybe_create_gone_author(_, _), do: nil

  # which import job each of a source's lists goes to
  @list_ops %{
    following: "follows_import",
    requests: "follows_import",
    ghosted: "ghosts_import",
    silenced: "silences_import",
    blocked: "blocks_import",
    bookmarks: "bookmarks_import",
    likes: "likes_import",
    boosts: "boosts_import",
    circles: "circles_import"
  }

  @doc "Checks an uploaded archive zip and lists what it holds (see `staged_items/1`), without importing anything yet."
  def stage_archive(zip_path), do: Bonfire.Social.Import.Source.Archive.stage(zip_path)

  @doc "What a staged import offers, each with `key`, `label`, `count`, `importable?` and the `reason` when it isn't."
  def staged_items(%{items: items}), do: items

  @doc "The dir on our server holding a staged import's files."
  def staged_dir(%{dir: dir}), do: dir

  @doc """
  Imports the picked items of a staged import into `scope` (a user).

  `only:` takes keys from `staged_items/1`, and anything not offered there as importable is refused. The staged dir comes from `staged` as the server kept it, never from the form.
  """
  def import_staged(scope, %{source: source, items: items} = staged, opts) do
    keys = List.wrap(opts[:only])
    importable = for %{importable?: true, key: key} <- items, do: key

    case keys -- importable do
      [] when keys != [] ->
        with {:ok, materialized} <- source.materialize(staged, keys) do
          user_id = Enums.id(scope)

          # small files first and the outbox last, so a large outbox doesn't hold up the rest
          lists =
            for {key, identifiers} <- materialized.lists, into: %{} do
              {key, enqueue_many(Map.fetch!(@list_ops, key), user_id, identifiers)}
            end

          posts =
            if :posts in keys and is_map(materialized.outbox) do
              %{
                posts:
                  import_from_json(:outbox, scope, materialized.outbox,
                    actor: materialized.actor,
                    media_dir: materialized.media_dir,
                    include_boosts: opts[:include_boosts]
                  )
              }
            else
              %{}
            end

          profile =
            if :profile in keys and is_map(materialized.actor),
              do: %{profile: import_profile(scope, materialized.actor, materialized.profile_dir)},
              else: %{}

          # the files that can't be imported, then the posts left out of the outbox
          skipped =
            for(%{importable?: false} = item <- items, do: Map.take(item, [:key, :reason])) ++
              List.wrap(e(posts, :posts, :skipped, []))

          {:ok,
           lists
           |> Map.merge(posts)
           |> Map.merge(profile)
           |> Map.put(:skipped, skipped)
           # eg. posts brought in visible only to the person
           |> Map.put(:notes, List.wrap(e(posts, :posts, :notes, [])))}
        end

      [] ->
        error(l("Please pick something to import"))

      not_offered ->
        error(not_offered, l("This archive doesn't hold that"))
    end
  end

  # the old account's profile, from its actor document: only what this profile doesn't have yet, never the name, and the avatar and banner from the archive's own copies
  defp import_profile(user, %{} = actor, staged_dir) do
    user = repo().maybe_preload(user, profile: [:icon, :image])
    profile = e(user, :profile, nil)

    text =
      %{
        "summary" => if(blank?(e(profile, :summary, nil)), do: actor["summary"]),
        "location" =>
          if(blank?(e(profile, :location, nil)),
            do:
              e(actor, "location", "name", nil) ||
                (is_binary(actor["location"]) && actor["location"]) || nil
          )
      }
      |> Enums.filter_empty(%{})

    with {:ok, user} <-
           if(text == %{}, do: {:ok, user}, else: Users.update(user, %{"profile" => text})) do
      for {kind, field, uploader} <- [
            {:icon, :icon_id, Bonfire.Files.IconUploader},
            {:banner, :image_id, Bonfire.Files.BannerUploader}
          ],
          is_nil(e(profile, field, nil)),
          url = e(actor, if(kind == :icon, do: "icon", else: "image"), "url", nil),
          path = is_binary(staged_dir) && staged_attachment_path(staged_dir, %{"url" => url}),
          is_binary(path) do
        with {:ok, media} <-
               Bonfire.Files.upload(uploader, user, path, %{client_name: Path.basename(path)}) do
          Bonfire.Me.Profiles.set_profile_image(kind, user, media)
        end
      end

      :ok
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""

  @doc false
  def enqueue_archive_cleanup(dir) do
    job_enqueue(
      [
        queue: :import,
        schedule_in: div(archive_retention(), 1000)
      ],
      %{"op" => "archive_cleanup", "dir" => dir}
    )
  end

  defp follows_from_csv_file(scope, path) do
    follows_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp follows_from_csv(scope, csv) do
    process_csv("follows_import", scope, csv)
  end

  defp ghosts_from_csv_file(scope, path) do
    ghosts_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp ghosts_from_csv(scope, csv) do
    process_csv("ghosts_import", scope, csv)
  end

  defp silences_from_csv_file(scope, path) do
    silences_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp silences_from_csv(scope, csv) do
    process_csv("silences_import", scope, csv)
  end

  defp blocks_from_csv_file(scope, path) do
    blocks_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp blocks_from_csv(scope, csv) do
    process_csv("blocks_import", scope, csv)
  end

  defp bookmarks_from_csv_file(scope, path) do
    bookmarks_from_csv(scope, read_file(path))
  end

  defp bookmarks_from_csv(scope, csv) do
    process_csv("bookmarks_import", scope, csv, false)
  end

  defp circles_from_csv_file(scope, path) do
    circles_from_csv(scope, read_file(path))
  end

  defp circles_from_csv(scope, csv) do
    process_csv("circles_import", scope, csv, false)
  end

  defp likes_from_csv_file(scope, path) do
    likes_from_csv(scope, read_file(path))
  end

  defp likes_from_csv(scope, csv) do
    process_csv("likes_import", scope, csv, false)
  end

  defp boosts_from_csv_file(scope, path) do
    boosts_from_csv(scope, read_file(path))
  end

  defp boosts_from_csv(scope, csv) do
    process_csv("boosts_import", scope, csv, false)
  end

  defp read_file(path) do
    path
    |> File.read!()

    # |> File.stream!(read_ahead: 100_000) # FIXME?
  end

  defp process_csv(type, scope, csv, with_header \\ true)

  defp process_csv("circles_import" = type, scope, csv, with_header) when is_binary(csv) do
    csv
    |> parse_pairs(with_header)
    |> enqueue_many(type, scope, ...)
  end

  defp process_csv(type, scope, csv, with_header) when is_binary(csv) do
    csv
    |> parse_list(with_header)
    |> enqueue_many(type, scope, ...)
  end

  defp process_csv("circles_import" = type, scope, csv, with_header) do
    # using Stream for circles with two columns
    csv
    |> CSV.parse_stream(skip_headers: with_header)
    |> Stream.map(fn data_cols ->
      case data_cols do
        [circle_name, username] ->
          enqueue_many(
            type,
            scope,
            {String.trim(circle_name), String.trim(username) |> String.trim_leading("@")}
          )

        _ ->
          # Skip invalid rows
          {:ok, %{errors: ["Invalid format"]}}
      end
    end)
    |> results_return()
  end

  #  for any other types that have a single (relevant) column
  defp process_csv(type, scope, csv, with_header) do
    # using Stream
    csv
    |> CSV.parse_stream(skip_headers: with_header)
    |> Stream.map(fn data_cols ->
      enqueue_many(
        type,
        scope,
        data_cols
        |> List.first()
        |> String.trim()
        |> String.trim_leading("@")
        # |> debug()
      )
    end)
    |> results_return()
  end

  @doc "The identifiers in a list file (handles or URLs, one per row, in the first column), as the CSV upload and an archive's lists both hold them."
  def parse_list(csv, with_header) when is_binary(csv) do
    csv
    |> parse_rows(with_header)
    # |> List.delete("Account address")
    |> Enum.map(&(&1 |> List.first() |> String.trim() |> String.trim_leading("@")))
    |> Enum.reject(&(&1 == ""))
  end

  @doc "The `{circle name, handle}` pairs in a circles file."
  def parse_pairs(csv, with_header) when is_binary(csv) do
    csv
    |> parse_rows(with_header)
    # For circles, we need both columns: circle_name,username
    |> Enum.map(fn row ->
      case row do
        [circle_name, username] ->
          {String.trim(circle_name), String.trim(username) |> String.trim_leading("@")}

        [_single_value] ->
          # If only one column, skip this row as it's invalid
          nil

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == {"", ""}))
  end

  defp parse_rows(csv, with_header) do
    case csv
         #  |> debug()
         |> CSV.parse_string(skip_headers: with_header) do
      # for cases where its a simple text file
      [] -> [[csv]]
      csv -> csv
    end
    |> debug()
  end

  # def follows_from_list(%User{} = follower, [_ | _] = identifiers) do
  #   enqueue_many("follows_import", follower, identifiers)
  # end

  # def ghosts_from_list(%User{} = ghoster, [_ | _] = identifiers) do
  #   enqueue_many("ghosts_import", ghoster, identifiers)
  # end

  # def silences_from_list(%User{} = scope, [_ | _] = identifiers) do
  #   enqueue_many("silences_import", scope, identifiers)
  # end

  # def blocks_from_list(%User{} = scope, [_ | _] = identifiers) do
  #   enqueue_many("blocks_import", scope, identifiers)
  # end

  defp enqueue_many(op, scope, identifiers, extra_args \\ %{})

  defp enqueue_many(op, scope, identifiers, extra_args) when is_list(identifiers) do
    identifiers
    |> Enum.map(fn identifier ->
      enqueue(op, scope, identifier, extra_args)
    end)
    |> results_return()
  end

  defp enqueue_many(op, scope, identifier, extra_args) do
    enqueue(op, scope, identifier, extra_args)
    |> List.wrap()
    |> results_return()
  end

  defp enqueue(op, scope, {circle_name, username}, _extra_args),
    do:
      job_enqueue([queue: :import], %{
        "op" => op,
        "user_id" => scope,
        "context" => circle_name,
        "identifier" => username
      })

  # `extra_args` carry what every item of one import shares, eg. the staged dir of an archive's media
  defp enqueue(op, scope, identifier, extra_args),
    do:
      job_enqueue(
        [queue: :import],
        Map.merge(extra_args, %{"op" => op, "user_id" => scope, "identifier" => identifier})
      )

  defp job_enqueue(spec, worker_args \\ []),
    do: job(spec, worker_args) |> Bonfire.Common.TestInstanceRepo.oban_insert()

  defp job(spec, worker_args \\ []), do: new(worker_args, spec)

  defp results_return(results) do
    results
    |> Enum.frequencies_by(fn
      {:ok, %{errors: errors}} when is_list(errors) and errors != [] and not is_nil(errors) ->
        error(errors, "import error")
        :error

      {:ok, result} ->
        debug(result, "import result")
        :ok

      other ->
        error(other, "import error")
        :error
    end)
  end

  @doc """
  Perform the queued job based on the operation and scope.

  ## Examples

      iex> perform(%{args: %{"op" => "follows_import", "user_id" => "user1", "identifier" => "id1"}})
      :ok

      iex> perform(%{args: %{"op" => "blocks_import", "user_id" => "instance_wide", "identifier" => "id1"}})
      :ok

  """
  def perform(%{args: %{"op" => "archive_cleanup", "dir" => dir}}) when is_binary(dir) do
    # only ever a dir staging made, so a job's args can't point the cleanup anywhere else
    if Path.dirname(dir) ==
         Path.expand(Config.get([__MODULE__, :archive_dir], System.tmp_dir!())) and
         String.starts_with?(Path.basename(dir), "import-") do
      # a job run before its time (Oban's inline mode runs scheduled jobs straight away) leaves the dir, since its import may not have read it yet
      with {:ok, %{mtime: mtime}} <- File.stat(dir, time: :posix),
           true <- System.os_time(:millisecond) - mtime * 1000 >= archive_retention() do
        File.rm_rf(dir)
      end

      :ok
    else
      error(dir, "Not a staged import dir, not deleting it")
    end
  end

  def perform(%{
        args: %{"op" => op, "user_id" => "instance_wide", "identifier" => identifier} = _args
      }) do
    # debug(args, op)
    perform(op, identifier, :instance_wide)
  end

  def perform(%{
        args:
          %{
            "op" => "circles_import",
            "user_id" => user_id,
            "context" => circle_name,
            "identifier" => username
          } = _args
      }) do
    with {:ok, user} <- Users.by_username(user_id) do
      perform("circles_import", {circle_name, username}, current_user: user)
    end
  end

  def perform(%{args: %{"op" => op, "user_id" => user_id, "identifier" => identifier} = args}) do
    # debug(args, op)
    with {:ok, user} <- Users.by_username(user_id) do
      perform(
        op,
        identifier,
        Enums.filter_empty([current_user: user, media_dir: args["media_dir"]], [])
      )
    end
  end

  defp archive_retention,
    do: Config.get([__MODULE__, :archive_retention]) || to_timeout(day: 7)

  @doc """
  Perform an import operation for the scope.

  ## Examples

      iex> perform("follows_import", scope, "identifier")

  """
  def perform("silences_import" = op, identifier, scope) do
    with {:ok, %{} = silence} <-
           AdapterUtils.get_by_url_ap_id_or_username(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _silenced} <- Blocks.block(silence, [:silence], scope) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("ghosts_import" = op, identifier, scope) do
    with {:ok, %{} = ghost} <-
           AdapterUtils.get_by_url_ap_id_or_username(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _ghosted} <- Blocks.block(ghost, [:ghost], scope) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("blocks_import" = op, identifier, scope) do
    with {:ok, %{} = ghost} <-
           AdapterUtils.get_by_url_ap_id_or_username(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _blocked} <- Blocks.block(ghost, [:ghost, :silence], scope) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("follows_import" = op, identifier, scope) do
    with {:ok, %{} = followed} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         # an import is re-runnable and its list routinely overlaps what the account already follows, so an existing follow is a success rather than an error to report per row
         {:ok, _followed} <- Follows.maybe_follow(Utils.current_user(scope), followed) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("bookmarks_import" = op, identifier, scope) do
    with {:ok, %{} = bookmarkable} <-
           AdapterUtils.get_or_fetch_and_create_by_uri(identifier),
         {:ok, _bookmark} <-
           Bonfire.Social.Bookmarks.bookmark(Utils.current_user(scope), bookmarkable) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("likes_import" = op, identifier, scope) do
    with {:ok, _like} <- import_object_action(:like, identifier, nil, Utils.current_user(scope)) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("boosts_import" = op, identifier, scope) do
    with {:ok, _boost} <- import_object_action(:boost, identifier, nil, Utils.current_user(scope)) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("circles_import" = op, {circle_name, username}, scope) do
    with {:ok, user} <- AdapterUtils.get_by_url_ap_id_or_username(username),
         {:ok, circle} <-
           Bonfire.Boundaries.Circles.get_or_create(circle_name, Utils.current_user(scope)),
         {:ok, _encircle} <- Bonfire.Boundaries.Circles.add_to_circles(user, circle) do
      :ok
    else
      error -> handle_error(op, "#{circle_name}; #{username}", error)
    end
  end

  def perform("outbox_creations_import" = op, identifier, scope) do
    with {:ok, _boost} <-
           process_json_activity(identifier, Utils.current_user(scope),
             include_boosts: false,
             media_dir: scope[:media_dir]
           ) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("outbox_import" = op, identifier, scope) do
    with {:ok, _boost} <-
           process_json_activity(identifier, Utils.current_user(scope),
             include_boosts: true,
             media_dir: scope[:media_dir]
           ) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform(_, _, _), do: :ok

  #  with {:ok, user} <- Users.by_username(user_id) do
  #     import_from_json(type, user_id, outbox_data, opts)
  #   else
  #     error ->
  #       error(error, "Failed to find user for outbox import")
  #   end

  # whether a post names an attachment by a path rather than a URL (as in a Mastodon archive) with no copy of it staged, so the embedded copy would import without it
  defp missing_relative_attachments?(%{} = object, media_dir) do
    object
    |> Map.get("attachment")
    |> List.wrap()
    |> Enum.any?(fn
      %{"type" => "Link"} ->
        false

      %{"url" => url} = attachment when is_binary(url) ->
        URI.parse(url).host in [nil, ""] and
          (is_nil(media_dir) or is_nil(staged_attachment_path(media_dir, attachment)))

      _ ->
        false
    end)
  end

  defp process_json_activity(
         %{"type" => "Create", "object" => %{"id" => object_id} = object} = activity,
         user,
         opts
       ) do
    media_dir = opts[:media_dir]

    cond do
      addressed_to_nobody?(activity) ->
        import_for_importer_only(activity, user, media_dir)

      missing_relative_attachments?(object, media_dir) and
          not match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: object_id)) ->
        # the origin's copy names its pictures by URL, so fetch it, and keep the embedded copy (without pictures) when the origin doesn't answer
        case import_object_action(:boost_imported_post, object_id, activity, user) do
          {:ok, _} = done ->
            done

          other ->
            warn(
              other,
              "Could not fetch #{object_id} for its pictures, importing it without them"
            )

            import_embedded_create(activity, object_id, user, media_dir)
        end

      true ->
        import_embedded_create(activity, object_id, user, media_dir)
    end
  end

  defp process_json_activity(%{"type" => "Create", "object" => object} = activity, user, _) do
    # For other Create activities where we don't have the full object, fetch the object before boosting
    with {:ok, boost} <- import_object_action(:boost_imported_post, object, activity, user) do
      if object = e(boost, :edge, :object, nil) || e(boost, :edge, :object_id, nil),
        do: maybe_fetch_thread_async(object, user |> repo().maybe_preload(:settings))

      {:ok, boost}
    end
  end

  defp process_json_activity(
         %{"type" => "Announce", "object" => object} = activity,
         user,
         opts
       ) do
    if opts[:include_boosts] do
      import_object_action(:boost, object, activity, user)
    else
      debug(activity, "Skipping a boost, since boosts weren't asked for")
      {:ok, nil}
    end
  end

  defp process_json_activity(%{"type" => type} = activity, _user, _) do
    msg = "Skipping unsupported activity type: #{type}"
    debug(activity, msg)
    {:ok, nil}
  end

  defp process_json_activity(invalid_activity, _user, _)
       when is_nil(invalid_activity) or invalid_activity == %{} or invalid_activity == "" do
    msg = "Skipping empty activity"
    debug(invalid_activity, msg)
    {:ok, nil}
  end

  defp process_json_activity(invalid_activity, _user, _) do
    msg = "Skipping unsupported activity structure"
    debug(invalid_activity, msg)
    {:ok, nil}
  end

  # A post of the person's own that was addressed to nobody: it comes in for them alone. Its boundary is set to just them, and it's boosted onto their profile without federating, so nothing about it reaches other servers
  defp import_for_importer_only(activity, user, media_dir) do
    # inserted with its addressing as it is, empty, so it comes in as a post (one with recipients would become a message), which the boundaries MRF accepts for this import alone
    with {:ok, inserted} <-
           maybe_insert_embedded_object(activity, user, media_dir, own_post_to_nobody: true),
         {:ok, post} <- pointable(inserted, user) do
      keep_to_importer_and_boost(post, user)
    end
  end

  # sets the post's boundary to just the importer, then boosts it onto their profile without federating
  defp keep_to_importer_and_boost(post, user) do
    with {_num, nil} <- Bonfire.Boundaries.Controlleds.remove_all_acls(post),
         # the importer as the creator: it's their own post, from their old account
         {:ok, _} <-
           Bonfire.Boundaries.Acls.set(post, user,
             boundary: "custom",
             to_circles: [Enums.id(user)]
           ) do
      do_object_action(:boost, post, nil, user)
    end
  end

  # a non-public post that isn't for its author's followers, and whose recipients this instance doesn't know (eg. a direct message to an account that's gone): nobody but its author could see it
  defp seen_by_nobody_else?(%{"object" => %{} = object} = activity) do
    not ActivityPub.Utils.public?(activity, object) and
      not AdapterUtils.addressed_to_author_followers?(activity) and
      AdapterUtils.all_known_recipient_characters(activity, object) == []
  end

  defp seen_by_nobody_else?(_), do: false

  defp pointable(%ActivityPub.Object{} = ap_object, user),
    do:
      Utils.maybe_apply(
        Bonfire.Federate.ActivityPub.AdapterUtils,
        :return_pointable,
        [ap_object, [current_user: user, verbs: [:boost]]]
      )

  defp pointable(pointer_id, _user) when is_binary(pointer_id),
    do: Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true)

  defp pointable(%{id: _} = pointable, _user), do: {:ok, pointable}

  defp import_embedded_create(activity, _object_id, user, media_dir) do
    # For Create activities with embedded objects, insert them directly without re-fetching
    with {:ok, inserted} <-
           maybe_insert_embedded_object(activity, user, media_dir) |> debug("created_object"),
         # an object this instance already had (a re-import, or a post fetched before) comes back as its pointer id
         {:ok, post} <- pointable(inserted, user) do
      # the recipients are only known once it's ingested (that fetched them), so this is decided here rather than before
      if seen_by_nobody_else?(activity),
        do: keep_to_importer_and_boost(post, user),
        else: do_object_action(:boost_imported_post, post, nil, user)
    end
  end

  defp import_object_action(action, id, published, user)
       when is_binary(id) and (is_binary(published) or is_nil(published)) do
    with {:ok, %{id: _} = object} <- AdapterUtils.get_or_fetch_and_create_by_uri(id) do
      do_object_action(action, object, published, user)
    else
      {:error, :not_found} ->
        error(id, "Could not find object to #{action}")

      {:error, e} ->
        error(e, "Could not fetch object to #{action}: #{id}")
        {:error, e}

      error ->
        error(error, "Failed to fetch object to #{action}")
    end
  end

  defp import_object_action(action, %{"id" => id} = object, activity, user) do
    import_object_action(
      action,
      id,
      e(activity, "published", nil) || e(object, "published", nil),
      user
    )
  end

  defp import_object_action(action, object, activity, user) when is_map(activity) do
    import_object_action(action, object, e(activity, "published", nil), user)
  end

  defp import_object_action(action, object, _activity, _user) do
    error(object, "Invalid object to #{action}")
  end

  defp do_object_action(action, %{id: object_pointer_id} = object, published, user) do
    # Generate ULID based on original activity date
    pointer_id =
      (published || Bonfire.Common.DatesTimes.date_from_pointer(object_pointer_id))
      |> debug("found_activity_date")
      |> Bonfire.Common.DatesTimes.generate_ulid_if_past()
      |> debug("generated_pointer_id")

    # Create action locally without federating, with original date
    case action do
      :like ->
        Bonfire.Social.Likes.like(user, object, skip_federation: true, pointer_id: pointer_id)
        |> debug("maybe_liked")

      :boost ->
        case Bonfire.Social.Boosts.boost(user, object,
               skip_federation: true,
               pointer_id: pointer_id
             ) do
          # reported as before, for the import status page, which lists this text among the errors it expects from re-importing
          {:error, :already_boosted} -> {:error, l("You already boosted this.")}
          other -> other
        end
        |> debug("maybe_boosted")

      # a post of the person's own, from their old account: the boost is listed in their outbox, so other servers can find it, but not delivered, since their followers already saw it
      :boost_imported_post ->
        case Bonfire.Social.Boosts.boost(user, object,
               skip_delivery: true,
               pointer_id: pointer_id
             ) do
          {:error, :already_boosted} -> {:error, l("You already boosted this.")}
          other -> other
        end
        |> debug("maybe_boosted imported post")
    end
  end

  # Helper to optionally fetch thread based on user setting
  defp maybe_fetch_thread_async(object, user) do
    debug(user, "user settings check for fetch_thread_on_import")

    if Settings.get(
         [Bonfire.Social.Import, :fetch_threads_on_import],
         false,
         current_user: user,
         name: l("Fetch thread replies on import"),
         description: l("Automatically fetch replies when importing posts.")
       ) do
      debug("scheduling fetch_thread_async for imported object")
      fetch_thread_async(object, user)
    end
  end

  defp fetch_thread_async(object, user) do
    # TODO: configurable whether user wants to do this?
    ActivityPub.Federator.Fetcher.fetch_thread(
      object,
      user_id: Enums.id(user),
      # TODO: clean/document these?
      mode: :async,
      fetch_collection: :async,
      fetch_collection_entries: :async,
      triggered_by: "import:fetch_thread_async"
    )
    |> debug("called fetch_thread_async")
  end

  @doc """
  Attempts to insert an embedded JSON object directly into the ActivityPub database.
  Returns {:ok, object_id} if successful, :not_embedded if it's just an ID, or {:error, reason} if failed.
  """
  defp maybe_insert_embedded_object(
         %{"object" => %{"id" => object_id} = object} = activity,
         user,
         media_dir,
         insert_opts \\ []
       ) do
    # Check if object already exists in cache
    case ActivityPub.Object.get_cached(ap_id: object_id) do
      {:ok, existing_object} ->
        debug(object_id, "Object already exists in cache")

        {:ok,
         e(existing_object, :pointer, nil) || e(existing_object, :pointer_id, nil) ||
           existing_object}

      {:error, :not_found} ->
        debug(object_id, "Object not cached, inserting embedded object directly")

        # Insert the embedded object directly (without re-fetching)
        with {:ok, inserted_object} <-
               ActivityPub.Federator.Fetcher.cached_or_handle_incoming(
                 activity,
                 [already_fetched: true, triggered_by: "import:embedded_object"] ++ insert_opts
               ) do
          maybe_fetch_thread_async(inserted_object, user)
          |> debug("Successfully inserted embedded object + scheduled thread fetching")

          inserted =
            e(inserted_object, :pointer, nil) || e(inserted_object, :pointer_id, nil) ||
              inserted_object

          maybe_attach_staged_media(user, inserted, object, media_dir)

          {:ok, inserted}
        else
          error ->
            error(error, "Failed to insert embedded object #{object_id}")
        end

      error ->
        error(error, "Error checking cache for #{object_id}")
    end
  end

  # an archive's own copy of each picture, attached to the post it came with. The copy wins over the origin's, which may be gone, so the post was inserted without it (a path isn't a URL `ap_receive_attachments` takes)
  defp maybe_attach_staged_media(user, post, %{} = object, media_dir) when is_binary(media_dir) do
    for attachment <- List.wrap(object["attachment"]),
        path = staged_attachment_path(media_dir, attachment),
        is_binary(path) do
      Bonfire.Files.ap_receive_local_attachment({user, post}, path, attachment)
      |> debug("attached staged media")
    end
  end

  defp maybe_attach_staged_media(_user, _post, _object, _media_dir), do: nil

  # where an attachment's file is in the staged dir: a relative `url` by its path (Mastodon writes it with a leading slash, the zip entry has none), an absolute one by `host/path`, then by `path`. A `Link` (eg. to a quoted post) is not a file.
  defp staged_attachment_path(_media_dir, %{"type" => "Link"}), do: nil

  defp staged_attachment_path(media_dir, %{"url" => url}) when is_binary(url) do
    uri = URI.parse(url)
    path = String.trim_leading(uri.path || "", "/")

    candidates =
      if uri.host in [nil, ""],
        do: [path],
        else: [Path.join(uri.host, path), path]

    Enum.find_value(candidates, fn relative ->
      with {:ok, safe} <- Path.safe_relative(relative),
           full = Path.join(media_dir, safe),
           {:ok, %{type: :regular}} <- File.lstat(full) do
        full
      else
        _ -> nil
      end
    end)
  end

  defp staged_attachment_path(_media_dir, _attachment), do: nil

  # defp handle_error(op, identifier, {:error, error}) do
  #   handle_error(op, identifier, error)
  # end

  # defp handle_error(_op, _identifier, error) when is_binary(error) or is_atom(error) do
  #   error(error)
  # end

  defp handle_error(op, identifier, error) when is_binary(identifier) do
    error(error, "could not import #{identifier}")
    {:error, Bonfire.Common.Errors.error_msg(error)}
  end

  defp handle_error(op, identifier, error) do
    error(error, "could not import #{inspect(identifier)}")
    {:error, Bonfire.Common.Errors.error_msg(error)}
  end
end
