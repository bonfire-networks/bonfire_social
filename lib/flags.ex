defmodule Bonfire.Social.Flags do
  @moduledoc """
  Flagging functionality

  This module handles flagging (reporting an activity or object to moderators and/or admins). It includes creating, querying, and managing flags, as well as handling federation through ActivityPub.

  Flags are implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions)
  """

  use Arrows
  use Bonfire.Common.Utils

  use Bonfire.Common.Repo,
    schema: Flag,
    searchable_fields: [:flagger_id, :flagged_id]

  alias Bonfire.Social
  # import Bonfire.Boundaries.Queries

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Identity.Named
  alias Bonfire.Data.Social.Flag
  # alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common
  # alias Bonfire.Me.Users
  # alias Bonfire.Data.Social.FlagCount
  alias Bonfire.Social.Activities
  # alias Bonfire.Social.FeedActivities

  alias Bonfire.Social.Edges
  # alias Bonfire.Social.Objects

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Flag
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: ["Flag", {"Create", "Flag"}, {"Undo", "Flag"}, {"Delete", "Flag"}]

  @doc """
  Checks if a user has flagged an object.

  ## Parameters

  - `user`: The user to check.
  - `object`: The object to check.

  ## Returns

  Boolean indicating whether the user has flagged the object.

  ## Examples

      iex> user = %Bonfire.Data.Identity.User{id: "user123"}
      iex> object = %Bonfire.Data.Social.Post{id: "post456"}
      iex> Bonfire.Social.Flags.flagged?(user, object)
      false
  """
  def flagged?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Retrieves a flag by subject and object.

  ## Parameters

  - `subject`: The subject (flagger) of the flag.
  - `object`: The object being flagged.
  - `opts`: Additional options (optional).

  ## Returns

  The flag if found, otherwise an error tuple.

  ## Examples

      iex> Bonfire.Social.Flags.get(subject, object)
      {:ok, %Bonfire.Data.Social.Flag{}}
  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Retrieves a flag by subject and object, raising an error if not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Retrieves flags created by a specific user.

  ## Parameters

  - `subject`: The flagger to query flags for.

  ## Returns

  A list of flags created by the subject.

  ## Examples

      iex> flagger = %Bonfire.Data.Identity.User{id: "user123"}
      iex> Bonfire.Social.Flags.by_flagger(flagger)
      [%Bonfire.Data.Social.Flag{}, ...]
  """
  def by_flagger(%{} = subject),
    do: [subjects: subject] |> query(current_user: subject) |> repo().many()

  @doc """
  Retrieves flags of a specific flagged object.

  ## Parameters

  - `object`: The object to query flags for.

  ## Returns

  A list of flags for the given object.

  ## Examples

      iex> object = %Bonfire.Data.Social.Post{id: "post456"}
      iex> Bonfire.Social.Flags.by_flagged(object)
      [%Bonfire.Data.Social.Flag{}, ...]
  """
  def by_flagged(%{} = object),
    do: [objects: object] |> query(current_user: object) |> repo().many()

  # def by_any(%User{}=user), do: repo().many(by_any_q(user))

  @doc """
  Records a flag.

  ## Parameters

  - `flagger`: The user creating the flag.
  - `flagged`: The object being flagged.
  - `opts`: Additional options (optional).

  ## Returns

  A tuple containing the created flag or an error.

  ## Examples

      iex> flagger = %Bonfire.Data.Identity.User{id: "user123"}
      iex> flagged = %Bonfire.Data.Social.Post{id: "post456"}
      iex> Bonfire.Social.Flags.flag(flagger, flagged)
      {:ok, %Bonfire.Data.Social.Flag{}}
  """
  def flag(flagger, flagged, opts \\ [])

  def flag(%{} = flagger, object, opts) do
    opts =
      opts
      |> Keyword.put_new(:current_user, flagger)
      |> Keyword.put_new_lazy(:to_feeds, fn -> flag_feeds(id(object), object_type(object)) end)

    case check_flag(flagger, object, opts)
         ~> create(flagger, ..., opts) do
      {:ok, flag} ->
        if id(flagger) not in maybe_apply(
             Bonfire.Federate.ActivityPub,
             :do_not_federate_user_ids,
             [],
             fallback_return: []
           ) do
          Social.maybe_federate_and_gift_wrap_activity(flagger, flag)
        else
          {:ok, flag}
        end

      e ->
        maybe_dup(flagger, object, e)
    end
  rescue
    e in Ecto.ConstraintError ->
      maybe_dup(flagger, object, e)
  end

  @doc """
  Retrieves moderators for a given object.

  ## Parameters

  - `object`: The object to find moderators for.

  ## Examples

      iex> object = %Bonfire.Data.Social.Post{id: "post456"}
      iex> Bonfire.Social.Flags.moderators(object)
  """
  def moderators(object),
    do: Bonfire.Boundaries.Controlleds.list_subjects_by_verb(object, :mediate)

  # |> debug("modddds")

  defp maybe_dup(flagger, object, e) do
    case get(flagger, object) do
      {:ok, flag} ->
        debug(flag, "the user already flagged this object")
        {:ok, flag}

      _ ->
        error(e)
    end
  end

  # determines the feeds a flag is published to
  defp flag_feeds(_object, :group),
    do:
      [notifications: instance_moderators()]
      |> debug("send flag of actual groups to instance moderators")

  # TODO: flag_feeds should be the group moderators if the object is in a group

  defp flag_feeds(object, _),
    do:
      [notifications: e(moderators(object), nil) || instance_moderators()]
      |> debug("send the flag to group moderators if any, otherwise instance moderators")

  @doc """
  Retrieves instance moderators.

  ## Returns

  A list of instance moderators.

  ## Examples

      iex> Bonfire.Social.Flags.instance_moderators()
      [%Bonfire.Data.Identity.User{}, ...]
  """
  # FIXME: should list actual instance moderators rather than admins
  def instance_moderators, do: Bonfire.Me.Users.list_admins()

  defp check_flag(_flagger, object, opts) do
    #  NOTE: currently allowing anyone to flag anything regardless of boundaries - TODO: make configurable?
    skip? = true

    opts =
      opts
      |> Keyword.put_new(:skip_boundary_check, true)

    # skip? = skip_boundary_check?(opts, object)
    # skip? = (:admins == skip? && Bonfire.Me.Accounts.is_admin?(flagger)) || skip? == true

    case object do
      %{id: id} ->
        if skip?,
          do: {:ok, object},
          else: Common.Needles.one(id, opts)

      _ when is_binary(object) ->
        if is_uid?(object) do
          Common.Needles.one(object, opts)
        else
          # try by username
          maybe_apply(Characters, :by_username, [object, opts])
        end
    end
  end

  @doc """
  Removes a flag created by a specific user on an object, if one exists.

  ## Parameters

  - `flagger`: The user who created the flag.
  - `flagged`: The flagged object or ID.

  ## Returns

  The result of the unflag operation.

  ## Examples

      iex> flagger = %Bonfire.Data.Identity.User{id: "user123"}
      iex> flagged = %Bonfire.Data.Social.Post{id: "post456"}
      iex> Bonfire.Social.Flags.unflag(flagger, flagged)
      :ok
  """
  def unflag(%User{} = flagger, %{} = flagged) do
    # delete the Flag
    Edges.delete_by_both(flagger, Flag, flagged)

    # delete the flag activity & feed entries (not needed unless publishing flags to feeds)
    Activities.delete_by_subject_verb_object(flagger, :flag, flagged)
  end

  def unflag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Common.Needles.get(object, current_user: user) do
      unflag(user, object)
    end
  end

  @doc """
  Lists flags based on given options.

  ## Parameters

  - `opts`: Options for filtering and pagination.

  ## Returns

  A paginated list of flags.

  ## Examples

      iex> Bonfire.Social.Flags.list(scope: :instance)
      %{page_info: %{}, edges: [%Bonfire.Data.Social.Flag{}, ...]}
  """
  def list(opts) do
    opts = opts ++ [preload: :object_with_creator]
    opts = to_options(opts)
    scope = opts[:scope]
    can_mediate_instance? = Bonfire.Boundaries.can?(opts, :mediate, :instance)

    opts =
      opts
      |> Keyword.put_new(
        :skip_boundary_check,
        can_mediate_instance? || :admins
      )

    if scope == :instance and
         can_mediate_instance? do
      list_paginated([], opts)
    else
      case id(scope) do
        id when is_binary(id) ->
          if Bonfire.Boundaries.can?(opts, :mediate, scope) do
            list_paginated([tree_parent: id], opts)
          else
            error(:not_permitted)
          end

        _ ->
          feed = list_paginated([], opts)

          edges =
            for %{edge: %{} = edge} <- e(feed, :edges, []),
                do: edge |> Map.put(:verb, %{verb: "Flag"})

          %{page_info: e(feed, :page_info, []), edges: edges}
      end
    end
  end

  @doc """
  Lists flags with preloaded associations.

  ## Parameters

  - `opts`: Options for filtering and pagination.

  ## Returns

  A paginated list of flags with preloaded associations.

  ## Examples

      iex> Bonfire.Social.Flags.list_preloaded(scope: :instance)
      %{page_info: %{}, edges: [%Bonfire.Data.Social.Flag{object: %{created: %{creator: %{}}}}, ...]}
  """
  def list_preloaded(opts) do
    list(opts)
    |> repo().maybe_preload(
      # [edge: [object: [created: [creator: [:profile, :character]]]]],
      [:named, object: [:media, :sensitive, created: [creator: [:profile, :character]]]],
      follow_pointers: false
    )
  end

  def list_paginated(filters, opts) do
    # mediators and admins should see all flagged objects

    filters
    |> query(opts)
    |> proload([:named])
    |> Social.many(opts[:paginate?], opts)

    # TODO: activity preloads?
  end

  @doc """
  Lists flags created by the current user.

  ## Parameters

  - `opts`: Options for filtering and pagination.

  ## Returns

  A paginated list of flags created by the current user.

  ## Examples

      iex> Bonfire.Social.Flags.list_my(current_user: %Bonfire.Data.Identity.User{id: "user123"})
      %{page_info: %{}, edges: [%Bonfire.Data.Social.Flag{}, ...]}
  """
  def list_my(opts), do: list_by(current_user_required!(opts), opts)

  @doc """
  Lists flags created by a specific user.

  ## Parameters

  - `by_user`: The user or user ID to filter flags by.
  - `opts`: Options for filtering and pagination (optional).

  ## Returns

  A paginated list of flags created by the specified user.

  ## Examples

      iex> Bonfire.Social.Flags.list_by("user123")
      %{page_info: %{}, edges: [%Bonfire.Data.Social.Flag{}, ...]}
  """
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    list_paginated(
      [subjects: by_user],
      opts
    )
  end

  @doc """
  Lists flags for a specific object.

  ## Parameters

  - `object`: The object or object ID to filter flags by.
  - `opts`: Options for filtering and pagination (optional).

  ## Returns

  A paginated list of flags for the specified object.

  ## Examples

      iex> Bonfire.Social.Flags.list_of("post456")
      %{page_info: %{}, edges: [%Bonfire.Data.Social.Flag{}, ...]}
  """
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    list_paginated(
      [objects: object],
      opts
    )
  end

  defp query_base(filters, opts) do
    # these keys are for us, not query_filter
    next =
      filters
      |> :proplists.delete(:objects, ...)
      |> :proplists.delete(:subjects, ...)

    Edges.query_parent(Flag, filters, opts)
    |> proload(
      edge: [
        subject: {"subject_", [:profile, :character]},
        object: {"object_", [:profile, :character, :post_content]}
      ]
    )
    |> query_filter(next)
  end

  def query([:all], opts), do: query([], opts)
  def query([my: :flags], opts), do: query([subjects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(subject, object, opts) do
    do_create(subject, object, opts[:comment], opts)
  end

  defp do_create(subject, object, nil, opts) do
    Edges.insert(Flag, subject, :flag, object, opts)
  end

  defp do_create(subject, object, comment, opts) do
    # TODO: check if comment is spam
    Edges.changeset(Flag, subject, :flag, object, opts)
    |> Ecto.Changeset.cast(%{named: %{name: comment}}, [])
    |> Needle.Changesets.cast_assoc(:named,
      with: fn cs, params ->
        Named.changeset(cs, params,
          normalize_fn: fn text ->
            Bonfire.Social.PostContents.prepare_text(text, subject, opts)
          end
        )
      end
    )
    |> debug("cssss")
    |> Edges.insert(subject, object)
  end

  @doc """
  Publishes a flag activity to ActivityPub.

  ## Parameters

  - `subject`: The subject (flagger) of the flag.
  - `_verb`: The verb associated with the flag (unused).
  - `flag`: The flag to publish.

  ## Returns

  The result of the ActivityPub publish operation.

  ## Examples

      iex> subject = %Bonfire.Data.Identity.User{id: "user123"}
      iex> flag = %Bonfire.Data.Social.Flag{}
      iex> Bonfire.Social.Flags.ap_publish_activity(subject, :flag, flag)
      {:ok, %ActivityPub.Object{}}
  """
  def ap_publish_activity(subject, _verb, %Flag{} = flag) do
    flagger = subject || e(flag, :edge, :subject, nil) || e(flag, :activity, :subject, nil)
    flagged = e(flag, :edge, :object, nil) || e(flag, :activity, :object, nil)

    with {:ok, flagger} <-
           ActivityPub.Actor.get_cached(pointer: flagger) do
      # FIXME: only works for flagged posts and users
      params =
        case Types.object_type(flagged) do
          User ->
            {:ok, account} = ActivityPub.Actor.get_cached(pointer: flagged)

            %{
              statuses: [],
              account: account
            }

          _ ->
            flagged =
              flagged
              |> repo().maybe_preload(:created)
              |> repo().maybe_preload(:creator)

            creator =
              e(flagged, :created, :creator_id, nil) || e(flagged, :creator, :id, nil) ||
                e(flagged, :creator_id, nil) || e(flag, :activity, :created, :creator_id, nil)

            account = if creator, do: ActivityPub.Actor.get_cached!(pointer: creator)

            %{
              statuses: [
                ActivityPub.Object.get_cached!(pointer: flagged)
              ],
              account: account
            }
        end

      ActivityPub.flag(
        %{
          # actor: flagger, # exclude actor so we send an anonymised flag instead (using a service actor)
          statuses: params.statuses,
          account: params.account,
          # TODO: ask the user if they want to forward the flag?
          forward: true,
          # content: flag.message, # TODO: add a comment
          forward: true,
          pointer: flag
        }
        |> debug("tooo_flag")
      )
    else
      e -> {:error, e}
    end
  end

  @doc """
  Receives a flag activity from ActivityPub for multiple objects.

  ## Parameters

  - `creator`: The creator of the flag.
  - `activity`: The ActivityPub activity.
  - `object`: An object or list of objects to be flagged.

  ## Returns

  A tuple containing the result of the flag operation.

  ## Examples

      iex> creator = %Bonfire.Data.Identity.User{id: "user123"}
      iex> activity = %{data: %{"type" => "Flag"}}
      iex> objects = [%{pointer_id: "post456"}, %{pointer_id: "post789"}]
      iex> Bonfire.Social.Flags.ap_receive_activity(creator, activity, objects)
      {:ok, [%Bonfire.Data.Social.Flag{}, %Bonfire.Data.Social.Flag{}]}
  """
  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Flag"}} = activity,
        objects
      )
      when is_list(objects) do
    case objects
         |> Enum.map(&ap_receive_activity(creator, activity, &1))
         # TODO: put this list of :ok / :error tuples logic somewhere reusable
         |> Enum.group_by(
           fn
             {:ok, _} -> :ok
             _ -> :error
           end,
           fn
             {:ok, val} -> val
             {:error, error} -> error
             other -> other
           end
         ) do
      %{ok: flags, error: errors} ->
        warn(errors, "Could not flag all the objects, but continuing with the ones that worked")
        {:ok, flags}

      %{ok: flags} ->
        {:ok, flags}

      %{error: errors} ->
        error(errors, "Could not flag any objects")
        # {_flags, errors} -> error(errors, "Could not flag all the objects")
    end
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Flag"}} = _activity,
        %{pointer_id: pointer_id}
      )
      when is_binary(pointer_id) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true) do
      flag(creator, object)
    end
  end

  def ap_receive_activity(
        _creator,
        _activity,
        other
      ) do
    error(other, "Could not find an object(s) to be flagged")
  end
end
