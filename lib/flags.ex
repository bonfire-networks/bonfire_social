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

  def flagged_object?(object),
    do: Edges.exists_for_object?(__MODULE__, object, skip_boundary_check: true)

  def subject_flagged_any?(user),
    do: Edges.exists_for_subject?(__MODULE__, user, skip_boundary_check: true)

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
      # Default to NOT forwarding for safety
      |> Keyword.put_new(:forward, false)
      |> debug("flag opts")

    case check_flag(flagger, object, opts)
         ~> create(flagger, ..., opts) do
      {:ok, flag} ->
        # looked up once, and only when the report may leave the instance
        group =
          if opts[:forward] == true or opts[:forward_to_group] == true,
            do: remote_group_for_report(object)

        maybe_send_to_group(flagger, object, group, opts)

        if opts[:forward] == true and opts[:skip_federation] != true and
             id(flagger) not in maybe_apply(
               Bonfire.Federate.ActivityPub,
               :do_not_federate_user_ids,
               [],
               fallback_return: []
             )
             |> debug("do_not_federate_user_ids") do
          Social.maybe_federate_and_gift_wrap_activity(flagger, flag,
            # the anonymous report names the remote group too, unless the reporter sent the group a named one
            anonymous_to_group: if(opts[:forward_to_group] != true, do: group)
          )
          |> debug("federated flag activity")
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

  @doc "The group on another instance that `object` is in, whose moderators a report about it can be sent to, or nil. A local group's moderators see reports on its moderation page already."
  def remote_group_for_report(object) do
    case maybe_apply(Bonfire.Classify.Categories, :group_of_object, [object],
           fallback_return: nil
         ) do
      {:ok, _, %{} = group} ->
        group = repo().maybe_preload(group, character: [:peered])
        if Social.is_local?(group), do: nil, else: group

      _ ->
        nil
    end
  end

  # A NAMED report to the moderators of the remote group the object is in, when the reporter asks for it (`forward_to_group: true`). Sent as the reporter, unlike the anonymous one: the threadiverse accepts a report only from a person (Lemmy's `Report.actor` is an `ApubPerson`), which the flag form warns about
  defp maybe_send_to_group(flagger, object, %{} = group, opts) do
    if opts[:forward_to_group] == true and opts[:skip_federation] != true and
         id(flagger) not in maybe_apply(
           Bonfire.Federate.ActivityPub,
           :do_not_federate_user_ids,
           [],
           fallback_return: []
         ) do
      with {:ok, %{ap_id: group_ap_id}} <- ActivityPub.Actor.get_cached(pointer: group),
           {:ok, reporter} <- ActivityPub.Actor.get_cached(pointer: flagger),
           {:ok, ap_object} <- ActivityPub.Object.get_cached(pointer: object) do
        ActivityPub.flag(%{
          actor: reporter,
          statuses: [ap_object],
          content: opts[:comment],
          # `summary` is where Lemmy reads the reason, `content` where Mastodon-family software does
          additional: %{
            "to" => [group_ap_id],
            "audience" => group_ap_id,
            "summary" => opts[:comment]
          }
        })
        |> debug("report sent to the group's moderators")
      else
        e -> debug(e, "could not send the report to the group")
      end
    end
  end

  # not in a remote group
  defp maybe_send_to_group(_flagger, _object, _group, _opts), do: nil

  # the anonymous report also names the remote group the object is in, so it reaches that group's moderators where their software accepts an anonymous report (Bonfire does, Lemmy does not)
  defp anonymous_to_group(%{} = group, content) do
    case ActivityPub.Actor.get_cached(pointer: group) do
      {:ok, %{ap_id: group_ap_id}} ->
        %{"to" => [group_ap_id], "audience" => group_ap_id, "summary" => content}

      _ ->
        %{}
    end
  end

  defp anonymous_to_group(_, _), do: %{}

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

  # In a group, the same recipients as a request to join it (`Categories.moderation_recipients/1`). The grant subjects `moderators/1` returns include the moderators CIRCLE rather than its members, and a circle has no feed, so they never heard of it
  defp flag_feeds(object, _) do
    case maybe_apply(Bonfire.Classify.Categories, :group_of_object, [object],
           fallback_return: nil
         ) do
      {:ok, _, %{} = group} ->
        [
          notifications:
            maybe_apply(Bonfire.Classify.Categories, :moderation_recipients, [group],
              fallback_return: [group]
            )
        ]
        |> debug("send the flag to the group and its moderators")

      _ ->
        [notifications: e(moderators(object), nil) || instance_moderators()]
        |> debug("send the flag to whoever moderates it, otherwise instance moderators")
    end
  end

  @doc """
  Retrieves instance moderators.

  ## Returns

  A list of instance moderators.

  ## Examples

      iex> Bonfire.Social.Flags.instance_moderators()
      [%Bonfire.Data.Identity.User{}, ...]
  """
  # FIXME: should list actual instance moderators rather than admins
  def instance_moderators, do: Bonfire.Me.Users.list_admins(preload: :internal)

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
      {:ok, 1}
  """
  def unflag(%User{} = flagger, %{} = flagged) do
    # before the Flag is gone, since that is how the anonymous report that went out is found
    withdraw_sent_reports(flagger, flagged)

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

  # A report withdrawn here is withdrawn wherever it went: the anonymous one (linked to the flag by `pointer:`) and the named one sent to a group (which can't be, since an AP object points at one local record, so it is found by reporter and object). Only reports WE sent: a remote reporter's own `Undo` also lands in `unflag/2`, and must not be answered with another in their name
  defp withdraw_sent_reports(flagger, flagged) do
    with {:ok, %{id: flag_id}} <- get(flagger, flagged),
         {:ok, %{data: %{"id" => flagged_ap_id}}} <-
           ActivityPub.Object.get_cached(pointer: flagged) do
      anonymous =
        case ActivityPub.Object.get_cached(pointer: flag_id) do
          {:ok, %{data: %{"type" => "Flag"}} = sent} -> [sent]
          _ -> []
        end

      named =
        case ActivityPub.Actor.get_cached(pointer: flagger) do
          {:ok, %{ap_id: reporter}} ->
            ActivityPub.Object.get_existing_flags(reporter, flagged_ap_id)

          _ ->
            []
        end

      for %{local: true} = sent <- Enum.uniq_by(anonymous ++ named, & &1.id),
          do: ActivityPub.unflag(%{flag: sent})
    end
  end

  @doc """
  Lists flags based on given options.

  ## Parameters

  - `opts`: Options for filtering and pagination.

  ## Returns

  A paginated list of flags.

  NOTE: this function doesn't seem to be used?

  ## Examples

      iex> Bonfire.Social.Flags.list(scope: :instance, current_user: an_admin_user)
      %{page_info: %{}, edges: [%Bonfire.Data.Social.Flag{}, ...]}
  """
  def list(opts) do
    opts = opts ++ [preload: :object_with_creator]
    opts = to_options(opts)
    scope = opts[:scope]
    scope_type = opts[:scope_type] || :tree_parent
    can_mediate_instance? = Bonfire.Boundaries.can?(opts, :mediate, :instance)

    opts =
      opts
      |> Keyword.put_new(
        :skip_boundary_check,
        can_mediate_instance? || :admins
      )

    if scope == :instance and
         can_mediate_instance? do
      debug("Listing all flags for instance moderators")
      list_paginated([], opts)
    else
      debug(scope, "Listing flags for scope")

      case id(scope) do
        id when is_binary(id) ->
          if can_mediate_instance? || Bonfire.Boundaries.can?(opts, :mediate, scope) do
            list_paginated([{scope_type, id}], opts)
          else
            error(:not_permitted)
          end

        _ ->
          if can_mediate_instance? do
            list_paginated([], opts)
          else
            error(:not_permitted)
          end
      end
    end
  end

  @doc """
  Lists flags with preloaded associations.

  NOTE: this function doesn't seem to be used?

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
      # superset: flagged objects vary in type — pruned to what each schema has
      [:named, object: [:media, :sensitive, created: [creator: [:profile, :character]]]],
      follow_pointers: false,
      prune: true
    )
  end

  defp list_paginated(filters, opts) do
    # mediators and admins should see all flagged objects (WARNING: this function does not apply boundary checks!)

    filters
    |> query(opts)
    |> proload([:named])
    |> debug("flags query")
    |> repo().many_maybe_paginated(opts[:paginate?], opts)
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

  WARNING: this should only be used by moderators/admins as it bypasses boundary checks!

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
  def ap_publish_activity(subject, _verb, %Flag{} = flag, opts \\ []) do
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
            # either creator shape depending on the flagged object's type — pruned per schema
            flagged =
              repo().maybe_preload(flagged, [:created, :creator], prune: true)

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

      content = e(flag, :named, :name, nil)

      ActivityPub.flag(
        %{
          # actor: flagger, # exclude actor so we send an anonymised flag instead (using a service actor)
          statuses: params.statuses,
          account: params.account,
          content: content,
          # assume true here because we are skipping federation in flag/3
          forward: opts[:forward] != false,
          pointer: flag,
          additional: anonymous_to_group(opts[:anonymous_to_group], content)
        }
        |> debug("publish flag params")
      )
      |> debug("published_flag")
    else
      e -> err(e, "Could not federate flag activity")
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
        activity,
        [object]
      ) do
    ap_receive_activity(
      creator,
      activity,
      object
    )
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Flag"}} = activity,
        objects
      )
      when is_list(objects) do
    case objects
         |> Enum.map(&ap_receive_activity(creator, activity, &1))
         # TODO: use reusable fn from Enums
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
        error(errors, "Could not flag all the objects, but continuing with the ones that worked")
        {:ok, flags}

      %{ok: flags} ->
        {:ok, flags}

      %{error: errors} ->
        err(errors, "Could not flag any objects")
        # {_flags, errors} -> error(errors, "Could not flag all the objects")
    end
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Flag"}} = activity,
        %{pointer_id: pointer_id}
      )
      when is_binary(pointer_id) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true) do
      # Extract the comment from the ActivityPub flag activity
      comment = e(activity, :data, "content", nil)

      flag(creator, object, comment: comment)
      |> debug("incoming federated flag created")
    end
  end

  def ap_receive_activity(
        _creator,
        %{data: %{"type" => "Flag"}} = _activity,
        object
      ) do
    error(object, "Could not find object(s) to be flagged")
  end

  # A reporter on another instance withdrawing their report: what it named comes from the undone `Flag`, embedded in the `Undo` or as the stored object. Loaded without a boundary check, since what is undone is the reporter's own report rather than anything they need to see
  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Undo"} = data} = _activity,
        object
      ) do
    flagged = e(data, "object", "object", nil) || e(object, :data, "object", nil)

    case List.wrap(flagged)
         |> Enum.flat_map(&flagged_pointer_ids/1)
         |> Enum.map(fn pointer_id ->
           with {:ok, flagged} <-
                  Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true) do
             unflag(creator, flagged)
           end
         end) do
      [] -> error(flagged, "Could not find what the withdrawn report was about")
      results -> {:ok, results}
    end
  end

  # a report names posts and the account, which are cached as objects and actors respectively
  defp flagged_pointer_ids(flagged) do
    ap_id = ActivityPub.Object.get_ap_id(flagged)

    with {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) <-
           ActivityPub.Object.get_cached(ap_id: ap_id) do
      [pointer_id]
    else
      _ ->
        case ActivityPub.Actor.get_cached(ap_id: ap_id) do
          {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) -> [pointer_id]
          _ -> []
        end
    end
  end

  def ap_receive_activity(
        _creator,
        activity,
        _object
      ) do
    error(activity, "Did not recognise flag activity")
  end
end
