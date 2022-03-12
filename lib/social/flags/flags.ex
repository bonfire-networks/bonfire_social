defmodule Bonfire.Social.Flags do

  use Arrows
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Flag
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common
  alias Bonfire.Me.Users
  # alias Bonfire.Data.Social.FlagCount
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo,
    schema: Flag,
    searchable_fields: [:flagger_id, :flagged_id]
  import Bonfire.Boundaries.Queries

  def queries_module, do: Flag
  def context_module, do: Flag
  def federation_module, do: ["Flag", {"Create", "Flag"}, {"Undo", "Flag"}, {"Delete", "Flag"}]

  def flagged?(%User{}=user, object), do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []), do: Edges.get(__MODULE__, subject, object, opts)
  def get!(subject, object, opts \\ []), do: Edges.get!(__MODULE__, subject, object, opts)

  def by_flagger(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()
  def by_flagged(%{}=object), do: [object: object] |> query(current_user: object) |> repo().many()
  # def by_any(%User{}=user), do: repo().many(by_any_q(user))

  def flag(flagger, flagged, opts \\ [])
  def flag(%{} = flagger, object, opts) do
    opts = Keyword.put_new(opts, :current_user, flagger)
    check_flag(flagger, object, opts)
    ~> do_flag(flagger, ..., opts)
  end

  defp check_flag(flagger, object, opts) do
    skip? = skip_boundary_check?(opts)
    skip? = (:admins == skip? && Users.is_admin?(flagger)) || (skip? == true)
    case object do
      %{id: id} ->
        if skip?, do: {:ok, object},
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

  defp do_flag(flagger, flagged, opts) do
    with {:ok, flag} <- create(flagger, flagged, opts),
         {:ok, activity} <- FeedActivities.notify_admins(flagger, :flag, {flagged, flag}) do
      # debug(activity: activity)
      # FeedActivities.publish(flagger, activity, {flagged, flag})
      {:ok, Activities.activity_under_object(activity, flag)}
    end
  end

  def unflag(%User{}=flagger, %{}=flagged) do
    Edges.delete_by_both(flagger, Flag, flagged) # delete the Flag
    Activities.delete_by_subject_verb_object(flagger, :flag, flagged) # delete the flag activity & feed entries (not needed unless publishing flags to feeds)
  end
  def unflag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Common.Pointers.get(object, current_user: user) do
      unflag(user, object)
    end
  end

  def list_paginated(filters, current_user_or_socket_or_opts \\ []) do
    opts =
      to_options(current_user_or_socket_or_opts)
      |> Keyword.put_new(:skip_boundary_check, :admins)
    filters
    |> query(opts)
    |> proload(:activity)
    |> Bonfire.Repo.many_paginated(opts)
    # TODO: activity preloads
  end

  @doc "List current user's flags, which are in their outbox"
  def list_my(opts), do: list_by(current_user(opts), opts)

  @doc "List flags by the user and which are in their outbox"
  def list_by(by_user, opts \\ []) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    [subject: by_user]
    |> list_paginated(opts)
  end

  @doc "List flag of an object and which are in a feed"
  def list_of(object, opts \\ []) when is_binary(object) or is_list(object) or is_map(object) do
    [object: object]
    |> list_paginated(opts)
  end

  defp query_base(filters, opts) do
    # these keys are for us, not query_filter
    next =
      filters
      |> :proplists.delete(:object, ...)
      |> :proplists.delete(:subject, ...)
    Edges.query_parent(Flag, filters, opts)
    |> proload([
      edge: [
        subject: {"subject_", [:profile, :character]},
        object: {"object_", [:profile, :character, :post_content]}
      ]
    ])
    |> query_filter(next)
  end

  def query([:all], opts), do: query([], opts)
  def query([my: :flags], opts), do: query([subject: current_user(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(flagger, flagged, preset_or_custom_boundary) do
    Edges.changeset(Flag, flagger, :flag, flagged, preset_or_custom_boundary)
    |> repo().insert()
  end


  def ap_publish_activity("create", %Flag{} = flag) do
    flag = repo().preload(flag, flagged: [])

    with {:ok, flagger} <- ActivityPub.Actor.get_cached_by_local_id(flag.flagger_id) do
      flagged = Common.Pointers.follow!(flag.context)

      #FIXME: only works for flagged posts and users
      params =
        case flagged do
          %User{id: id} when not is_nil(id) ->

            {:ok, account} =
              ActivityPub.Actor.get_by_local_id(id)

            %{
              statuses: nil,
              account: account
            }

          %Bonfire.Data.Social.Post{} = flagged ->
            flagged = repo().preload(flagged, :created)

            {:ok, account} =
              ActivityPub.Actor.get_or_fetch_by_username(
                flagged.created.creator_id
              )

            %{
              statuses: [ActivityPub.Object.get_cached_by_pointer_id(flagged.id)],
              account: account
            }
        end

      ActivityPub.flag(
        %{
          actor: flagger,
          context: ActivityPub.Utils.generate_context_id(),
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
