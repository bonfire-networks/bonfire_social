defmodule Bonfire.Social.Flags do
  use Arrows
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Flag
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common
  alias Bonfire.Me.Users
  # alias Bonfire.Data.Social.FlagCount
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  use Arrows
  use Bonfire.Common.Utils

  use Bonfire.Common.Repo,
    schema: Flag,
    searchable_fields: [:flagger_id, :flagged_id]

  import Bonfire.Boundaries.Queries

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Flag

  def federation_module,
    do: ["Flag", {"Create", "Flag"}, {"Undo", "Flag"}, {"Delete", "Flag"}]

  def flagged?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def by_flagger(%{} = subject),
    do: [subject: subject] |> query(current_user: subject) |> repo().many()

  def by_flagged(%{} = object),
    do: [object: object] |> query(current_user: object) |> repo().many()

  # def by_any(%User{}=user), do: repo().many(by_any_q(user))

  def flag(flagger, flagged, opts \\ [])

  def flag(%{} = flagger, object, opts) do
    opts =
      opts
      |> Keyword.put_new(:current_user, flagger)
      |> Keyword.put_new_lazy(:to_feeds, &flag_feeds/0)

    check_flag(flagger, object, opts)
    ~> create(flagger, ..., opts)
  rescue
    e in Ecto.ConstraintError ->
      warn(e)
      {:ok, "Already flagged"}
  end

  # determines the feeds a flag is published to
  defp flag_feeds(), do: [notifications: Bonfire.Me.Users.list_admins()]

  defp check_flag(flagger, object, opts) do
    skip? = skip_boundary_check?(opts, object)
    skip? = (:admins == skip? && Users.is_admin?(flagger)) || skip? == true

    case object do
      %{id: id} ->
        if skip?,
          do: {:ok, object},
          else: Common.Pointers.one(id, opts)

      _ when is_binary(object) ->
        if is_ulid?(object) do
          Common.Pointers.one(object, opts)
        else
          # try by username
          maybe_apply(Characters, :by_username, [object, opts])
        end
    end
  end

  def unflag(%User{} = flagger, %{} = flagged) do
    # delete the Flag
    Edges.delete_by_both(flagger, Flag, flagged)

    # delete the flag activity & feed entries (not needed unless publishing flags to feeds)
    Activities.delete_by_subject_verb_object(flagger, :flag, flagged)
  end

  def unflag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Common.Pointers.get(object, current_user: user) do
      unflag(user, object)
    end
  end

  def list_paginated(filters, opts \\ []) do
    # mediators and admins should see all flagged objects
    opts =
      Keyword.put_new(
        to_options(opts),
        :skip_boundary_check,
        Bonfire.Boundaries.can?(opts, :mediate, :instance) || :admins
      )

    filters
    |> query(opts)
    |> proload(:activity)
    |> repo().many_paginated(opts)

    # TODO: activity preloads
  end

  @doc "List current user's flags, which are in their outbox"
  def list_my(opts), do: list_by(current_user_required!(opts), opts)

  @doc "List flags by the user and which are in their outbox"
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    list_paginated(
      [subject: by_user],
      opts
    )
  end

  @doc "List flag of an object and which are in a feed"
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    list_paginated(
      [object: object],
      opts
    )
  end

  defp query_base(filters, opts) do
    # these keys are for us, not query_filter
    next =
      filters
      |> :proplists.delete(:object, ...)
      |> :proplists.delete(:subject, ...)

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
  def query([my: :flags], opts), do: query([subject: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(flagger, flagged, opts) do
    Edges.insert(Flag, flagger, :flag, flagged, opts)
  end

  def ap_publish_activity(subject, _verb, %Flag{} = flag) do
    flag = repo().preload(flag, flagged: [])

    with {:ok, flagger} <-
           ActivityPub.Actor.get_cached(pointer: subject || flag.flagger_id) do
      flagged = Common.Pointers.get(flag.context)

      # FIXME: only works for flagged posts and users
      params =
        case flagged do
          %User{id: id} when not is_nil(id) ->
            {:ok, account} = ActivityPub.Actor.get_cached(pointer: id)

            %{
              statuses: [],
              account: account
            }

          %Bonfire.Data.Social.Post{} = flagged ->
            flagged = repo().preload(flagged, :created)

            {:ok, account} =
              ActivityPub.Actor.get_or_fetch_by_username(flagged.created.creator_id)

            %{
              statuses: [
                ActivityPub.Object.get_cached!(pointer: ulid(flagged))
              ],
              account: account
            }
        end

      ActivityPub.flag(
        %{
          actor: flagger,
          statuses: params.statuses,
          account: params.account,
          content: flag.message,
          forward: true
        },
        flag.id
      )
    else
      e -> {:error, e}
    end
  end
end
