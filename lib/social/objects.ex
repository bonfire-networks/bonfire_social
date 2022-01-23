defmodule Bonfire.Social.Objects do

  use Arrows
  use Bonfire.Repo,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]
  use Bonfire.Common.Utils, only: [debug: 1, debug: 2]

  alias Bonfire.Common.Pointers
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Me.Acls
  alias Bonfire.Social.{Activities, Tags, Threads}

  def cast(changeset, attrs, creator, preset_or_custom_boundary) do
    # debug(creator, "creator")
    changeset
    |> cast_creator(creator)
    # record replies & threads. preloads data that will be checked by `Acls`
    |> Threads.cast(attrs, creator, preset_or_custom_boundary)
    # record tags & mentions. uses data preloaded by `PostContents`
    |> Tags.cast(attrs, creator, preset_or_custom_boundary)
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    |> Acls.cast(creator, preset_or_custom_boundary)
    |> Activities.cast(:create, creator, preset_or_custom_boundary)
    # |> debug()
  end

  defp cast_creator(changeset, creator),
    do: cast_creator(changeset, creator, Utils.e(creator, :id, nil))

  defp cast_creator(changeset, _creator, nil), do: changeset
  defp cast_creator(changeset, _creator, creator_id) do
    changeset
    |> Changeset.cast(%{created: %{creator_id: creator_id}}, [])
    |> Changeset.cast_assoc(:created)
  end

  defp cast_creator_caretaker(changeset, creator),
    do: cast_creator_caretaker(changeset, creator, Utils.e(creator, :id, nil))

  defp cast_creator_caretaker(changeset, _creator, nil), do: changeset
  defp cast_creator_caretaker(changeset, _creator, creator_id) do
    changeset
    |> Changeset.cast(%{created: %{creator_id: creator_id}}, [])
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast(%{caretaker: %{caretaker_id: creator_id}}, [])
    |> Changeset.cast_assoc(:caretaker)
  end

  def read(object_id, socket_or_current_user) when is_binary(object_id) do
    current_user = Utils.current_user(socket_or_current_user) #|> IO.inspect
    Pointers.pointer_query([id: object_id], socket_or_current_user)
    |> Activities.read(socket: socket_or_current_user, skip_boundary_check: true)
    # |> Utils.debug("activities")
    ~> maybe_preload_activity_object(current_user)
    |> ok(Activities.activity_under_object(...))
  end

  def maybe_preload_activity_object(%{activity: %{object: _}} = pointer, current_user) do
    Preload.maybe_preload_nested_pointers pointer, [activity: [:object]],
      current_user: current_user, skip_boundary_check: true
  end
  def maybe_preload_activity_object(pointer, _current_user), do: pointer

  def preload_reply_creator(object) do
    object
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [created: [creator: [:character]]]]]) #|> IO.inspect
    # |> Bonfire.Repo.maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [creator: [:character]]]]) #|> IO.inspect
  end

  # TODO: does not take permissions into consideration
  def preload_creator(object),
    do: Bonfire.Repo.maybe_preload(object, [created: [creator: [:character]]])

  def object_creator(object) do
    Utils.e(object, :created, :creator, :character, Utils.e(object, :creator, nil))
  end

  defp tag_ids(tags), do: Enum.map(tags, &(&1.id))

  # # used for public and mentions presets. returns a list of feed ids
  # defp inboxes(tags) when is_list(tags), do: Enum.flat_map(tags, &inboxes/1)
  # defp inboxes(%{character: %Character{inbox: %Inbox{feed_id: id}}})
  # when not is_nil(id), do: [id]
  # defp inboxes(_), do: []

  # # used for public preset. if the creator is me, the empty list, else a list of one feed id
  # defp reply_to_inboxes(changeset, %{id: me}, "public") do
  #   case get_in(changeset, [:changes, :replied, :data, :reply_to]) do
  #     %{created: %{creator_id: creator}, character: %{inbox: %{feed_id: feed}}}
  #     when not is_nil(feed) and not is_nil(creator) and not creator == me -> [feed]
  #     _ -> []
  #   end
  # end
  # defp reply_to_inboxes(_, _, _), do: []


    # if we see tags, we load them and will one day verify you are permitted to use them
    # feeds = reply_to_inboxes(changeset, creator, preset) ++ inboxes(mentions)
    # with {:ok, activity} <- do_pub(subject, verb, object, circles) do
    #   # maybe_make_visible_for(subject, object, circles ++ tag_ids(tags))
    #   Threads.maybe_push_thread(subject, activity, object)
    #   notify_inboxes(subject, activity, object, feeds)
    # end



end
