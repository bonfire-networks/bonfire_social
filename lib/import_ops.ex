defmodule Bonfire.Social.ImportOps do
  @moduledoc """
  The import ops for what `bonfire_social` owns: follows, likes, boosts and bookmarks, in the op role of `Bonfire.Common.ImportModule`. `Bonfire.Common.Import`'s worker hands each queued job to `perform_import/3`.
  """
  @behaviour Bonfire.Common.ImportModule

  import Untangle
  use Bonfire.Common.E
  use Bonfire.Common.Localise
  alias Bonfire.Common.Utils
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @impl Bonfire.Common.ImportModule
  def import_ops, do: ["follows_import", "likes_import", "boosts_import", "bookmarks_import"]

  @impl Bonfire.Common.ImportModule
  def import_op_label("follows_import"), do: l("Follow")
  def import_op_label("likes_import"), do: l("Like")
  def import_op_label("boosts_import"), do: l("Boost")
  def import_op_label("bookmarks_import"), do: l("Bookmark")
  def import_op_label(_), do: nil

  @impl Bonfire.Common.ImportModule
  def import_op_phrase("follows_import"), do: l("Following user")
  def import_op_phrase("likes_import"), do: l("Importing like")
  def import_op_phrase("boosts_import"), do: l("Importing boost")
  def import_op_phrase("bookmarks_import"), do: l("Importing bookmark")
  def import_op_phrase(_), do: nil

  @doc """
  Imports one item, for the scope: called by `Bonfire.Common.Import`'s worker for each queued job of an op in `import_ops/0`.

  ## Examples

      iex> perform_import("follows_import", "identifier", current_user: user)

  """
  @impl Bonfire.Common.ImportModule
  def perform_import("follows_import" = op, identifier, scope) do
    with {:ok, %{} = followed} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         # an import is re-runnable and its list routinely overlaps what the account already follows, so an existing follow is a success rather than an error to report per row
         {:ok, _followed} <- Follows.maybe_follow(Utils.current_user(scope), followed) do
      :ok
    else
      error -> Bonfire.Common.Import.handle_error(op, identifier, error)
    end
  end

  def perform_import("bookmarks_import" = op, identifier, scope) do
    with {:ok, %{} = bookmarkable} <-
           AdapterUtils.get_or_fetch_and_create_by_uri(identifier),
         {:ok, _bookmark} <-
           Bonfire.Social.Bookmarks.bookmark(Utils.current_user(scope), bookmarkable) do
      :ok
    else
      error -> Bonfire.Common.Import.handle_error(op, identifier, error)
    end
  end

  def perform_import("likes_import" = op, identifier, scope) do
    with {:ok, _like} <- import_object_action(:like, identifier, nil, Utils.current_user(scope)) do
      :ok
    else
      error -> Bonfire.Common.Import.handle_error(op, identifier, error)
    end
  end

  def perform_import("boosts_import" = op, identifier, scope) do
    with {:ok, _boost} <- import_object_action(:boost, identifier, nil, Utils.current_user(scope)) do
      :ok
    else
      error -> Bonfire.Common.Import.handle_error(op, identifier, error)
    end
  end

  @doc """
  Finds or fetches the object (by its id, or the `"id"` of an embedded object), then likes or boosts it as `user` with `do_object_action/4`, dated from `published` (or the activity's `"published"`). Shared with the outbox import, which boosts the person's own imported posts.
  """
  def import_object_action(action, id, published, user)
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

  def import_object_action(action, %{"id" => id} = object, activity, user) do
    import_object_action(
      action,
      id,
      e(activity, "published", nil) || e(object, "published", nil),
      user
    )
  end

  def import_object_action(action, object, activity, user) when is_map(activity) do
    import_object_action(action, object, e(activity, "published", nil), user)
  end

  def import_object_action(action, object, _activity, _user) do
    error(object, "Invalid object to #{action}")
  end

  @doc """
  Likes (`:like`) or boosts (`:boost`, or `:boost_imported_post` for the person's own post from their old account) an object found locally, without federating, with an id dated from `published` or the object's own date. Shared with the outbox import.
  """
  def do_object_action(action, %{id: object_pointer_id} = object, published, user) do
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
end
