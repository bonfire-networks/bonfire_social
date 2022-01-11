defmodule Bonfire.Social.Flags do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Flag
  alias Bonfire.Boundaries.Verbs
  # alias Bonfire.Data.Social.FlagCount
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Social.Edges

  use Bonfire.Repo,
    searchable_fields: [:flagger_id, :flagged_id]
  import Bonfire.Common.Utils

  # def queries_module, do: Flag
  def context_module, do: Flag
  def federation_module, do: ["Flag", {"Create", "Flag"}, {"Undo", "Flag"}, {"Delete", "Flag"}]

  def flagged?(%User{}=user, object), do: not is_nil(get!(user, object))

  def get(subject, object), do: [subject: subject, object: object] |> query(current_user: subject) |> repo().single()
  def get!(subject, objects) when is_list(objects), do: [subject: subject, object: objects] |> query(current_user: subject) |> repo().all()
  def get!(subject, object), do: [subject: subject, object: object] |> query(current_user: subject) |> repo().one()

  def by_flagger(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()
  def by_flagged(%{}=object), do: [object: object] |> query(current_user: object) |> repo().many()
  # def by_any(%User{}=user), do: repo().many(by_any_q(user))

  def flag(%User{} = flagger, %{} = flagged) do
    with {:ok, flag} <- create(flagger, flagged) do
      # TODO: increment the flag count
      # TODO: put in admin(s) inbox feed?

      {:ok, activity} = FeedActivities.notify_admins(flagger, :flag, flagged)

      with_activity = Activities.activity_under_object(activity, flag) #|> IO.inspect()
      {:ok, with_activity}
    end
  end
  def flag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      flag(user, object)
    end
  end

  def unflag(%User{}=flagger, %{}=flagged) do
    Edges.delete_by_both(flagger, flagged) # delete the Flag
    Activities.delete_by_subject_verb_object(flagger, :flag, flagged) # delete the flag activity & feed entries (not needed unless publishing flags to feeds)
    # TODO: decrement the flag count
  end
  def unflag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      unflag(user, object)
    end
  end


  def list_paginated(filters, opts \\ []) do
    filters
    |> query(opts)
    |> Bonfire.Repo.many_paginated(opts)
    # TODO: activity preloads
  end

  @doc "List current user's flags, which are in their outbox"
  def list_my(opts) do
    list_by(current_user(opts), opts)
  end

  @doc "List flags by the user and which are in their outbox"
  def list_by(by_user, opts \\ []) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    # query FeedPublish
    [subject: by_user ]
    |> list_paginated(opts)
  end

  @doc "List flag of an object and which are in a feed"
  def list_of(id, opts \\ []) when is_binary(id) or is_list(id) or is_map(id) do

    # query FeedPublish
    [object: id ]
    |> list_paginated(opts)
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Flag, filters, opts)
    # |> proload(edge: [
    #   # subject: {"booster_", [:profile, :character]},
    #   # object: {"boosted_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([:all], opts), do: [] |> query(opts)
  def query([my: :flags], opts), do: [subject: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(flagger, flagged) do
    Edges.changeset(Flag, flagger, flagged, "71AGSPAM0RVNACCEPTAB1E1TEM") |> repo().insert()
  end


  def ap_publish_activity("create", %Flag{} = flag) do
    flag = repo().preload(flag, flagged: [])

    with {:ok, flagger} <-
          ActivityPub.Actor.get_cached_by_local_id(flag.flagger_id) do
      flagged = Bonfire.Common.Pointers.follow!(flag.context)

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
