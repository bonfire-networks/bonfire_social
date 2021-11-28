defmodule Bonfire.Social.Flags do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Flag
  alias Bonfire.Boundaries.Verbs
  # alias Bonfire.Data.Social.FlagCount
  alias Bonfire.Social.{Activities, FeedActivities}
  use Bonfire.Repo.Query,
    searchable_fields: [:flagger_id, :flagged_id]
  import Bonfire.Common.Utils

  # def queries_module, do: Flag
  def context_module, do: Flag
  def federation_module, do: ["Flag", {"Create", "Flag"}, {"Undo", "Flag"}, {"Delete", "Flag"}]

  def flagged?(%User{}=user, flagged), do: not is_nil(get!(user, flagged))
  def get(%User{}=user, flagged), do: repo().single(by_both_q(user, flagged))
  def get!(%User{}=user, flagged), do: repo().one(by_both_q(user, flagged))
  def by_flagger(%User{}=user), do: repo().many(by_flagger_q(user))
  def by_flagged(%User{}=user), do: repo().many(by_flagged_q(user))
  def by_any(%User{}=user), do: repo().many(by_any_q(user))

  def flag(%User{} = flagger, %{} = flagged) do
    with {:ok, flag} <- create(flagger, flagged) do
      # TODO: increment the flag count
      # TODO: put in admin(s) inbox feed
      FeedActivities.notify_admins(flagger, :flag, flagged)
      {:ok, flag}
    end
  end
  def flag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      flag(user, object)
    end
  end

  def unflag(%User{}=flagger, %{}=flagged) do
    delete_by_both(flagger, flagged) # delete the Flag
    Activities.delete_by_subject_verb_object(flagger, :flag, flagged) # delete the flag activity & feed entries (not needed unless publishing flags to feeds)
    # TODO: decrement the flag count
  end
  def unflag(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      unflag(user, object)
    end
  end


  @doc "List flag of an object and which are in a feed"
  def list(current_user, cursor_after \\ nil, preloads \\ :all) when not is_nil(current_user) do
    # TODO: double check that we're admin
    # query FeedPublish
    [flags: {:all, &filter/3} ]
    |> FeedActivities.feed_paginated(current_user, cursor_after, preloads)
  end

  @doc "List current user's flags, which are in their outbox"
  def list_my(current_user, cursor_after \\ nil, preloads \\ :all) when is_binary(current_user) or is_map(current_user) do
    list_by(current_user, current_user, cursor_after, preloads)
  end

  @doc "List flags by the user and which are in their outbox"
  def list_by(by_user, current_user \\ nil, cursor_after \\ nil, preloads \\ :all) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    # query FeedPublish
    [flags_by: {ulid(by_user), &filter/3} ]
    |> FeedActivities.feed_paginated(current_user, cursor_after, preloads)
  end

  @doc "List flag of an object and which are in a feed"
  def list_of(id, current_user \\ nil, cursor_after \\ nil, preloads \\ :all) when is_binary(id) or is_list(id) or is_map(id) do

    # query FeedPublish
    [flags_of: {ulid(id), &filter/3} ]
    |> FeedActivities.feed_paginated(current_user, cursor_after, preloads)
  end


  defp create(%{} = flagger, %{} = flagged) do
    changeset(flagger, flagged) |> repo().insert()
  end

  defp changeset(%{id: flagger}, %{id: flagged}) do
    Flag.changeset(%Flag{}, %{flagger_id: flagger, flagged_id: flagged})
  end

  #doc "Delete flags where i am the flagger"
  defp delete_by_flagger(%User{}=me), do: elem(repo().delete_all(by_flagger_q(me)), 1)

  #doc "Delete flags where i am the flagged"
  defp delete_by_flagged(%User{}=me), do: elem(repo().delete_all(by_flagged_q(me)), 1)

  #doc "Delete flags where i am the flagger or the flagged."
  defp delete_by_any(%User{}=me), do: elem(repo().delete_all(by_any_q(me)), 1)

  #doc "Delete flags where i am the flagger and someone else is the flagged."
  defp delete_by_both(%User{}=me, %{}=flagged), do: elem(repo().delete_all(by_both_q(me, flagged)), 1)

  defp by_flagger_q(%User{id: id}) do
    from f in Flag,
      where: f.flagger_id == ^id,
      select: f.id
  end

  defp by_flagged_q(%User{id: id}) do
    from f in Flag,
      where: f.flagged_id == ^id,
      select: f.id
  end

  defp by_any_q(%User{id: id}) do
    from f in Flag,
      where: f.flagger_id == ^id or f.flagged_id == ^id,
      select: f.id
  end

  defp by_both_q(%User{id: flagger}, %{id: flagged}), do: by_both_q(flagger, flagged)

  defp by_both_q(flagger, flagged) when is_binary(flagger) and is_binary(flagged) do
    from f in Flag,
      where: f.flagger_id == ^flagger or f.flagged_id == ^flagged,
      select: f.id
  end

  #doc "List flags which are in a feed"
  def filter(:flags, :all, query) do
    verb_id = Verbs.verbs()[:flag]

    query
    |> join_preload([:activity])
    |> where(
      [activity: activity],
      activity.verb_id==^verb_id
    )
  end

  #doc "List flags created by the user and which are in their outbox"
  def filter(:flags_of, id, query) do
    verb_id = Verbs.verbs()[:flag]

    query
    |> join_preload([:activity])
    |> where(
      [activity: activity],
      activity.verb_id==^verb_id and activity.object_id == ^ulid(id)
    )
  end

  #doc "List flags created by the user and which are in their outbox"
  def filter(:flags_by, user_id, query) do
    verb_id = Verbs.verbs()[:flag]

      query
      |> join_preload([:activity, :subject_character])
      |> where(
        [activity: activity, subject_character: flagger],
        activity.verb_id==^verb_id and flagger.id == ^ulid(user_id)
      )
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
