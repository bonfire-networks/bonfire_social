defmodule Bonfire.Social.Objects do

  use Bonfire.Repo,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]

  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Inbox
  alias Bonfire.Social.{Activities, Tags, Threads}
  alias Bonfire.Common.Utils

  def cast(changeset, attrs, creator, preset) do
    creator_id = Utils.e(creator, :id, nil)

    if is_nil(creator_id) do
      changeset
    else # set creator
      changeset
      |> Changeset.cast(%{created: %{creator_id: creator_id}}, [])
      |> Changeset.cast_assoc(:created)
    end
    |> Threads.cast(attrs, creator, preset) # record replies & threads
    |> Tags.cast(attrs, creator, preset) # set tags & mentions
    |> Bonfire.Me.Acls.cast(creator, preset) # apply boundaries on all objects, should be last since it uses data set in threads & mentions
  end


  def read(object_id, socket_or_current_user) when is_binary(object_id) do

    current_user = Utils.current_user(socket_or_current_user) #|> IO.inspect

    with {:ok, pointer} <- Pointers.pointer_query([id: object_id], socket_or_current_user)
                          |> Activities.read(socket: socket_or_current_user, skip_boundary_check: true) #|> IO.inspect,
        #  {:ok, object} <- Bonfire.Common.Pointers.get(pointer, current_user: user)
        do

        # IO.inspect(read_object: pointer)

        {:ok,
          pointer
          |> maybe_preload_activity_object(current_user)
          |> Activities.activity_under_object()
        }
      end
  end


  def maybe_preload_activity_object(%{activity: %{object: _}} = pointer, current_user) do
    Preload.maybe_preload_nested_pointers pointer, [activity: [:object]],
      current_user: current_user, skip_boundary_check: true
  end
  def maybe_preload_activity_object(pointer, _current_user), do: pointer

  def preload_reply_creator(object) do
    object
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [created: [creator: [character: [:inbox]]]]]]) #|> IO.inspect
    # |> Bonfire.Repo.maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [creator: [character: [:inbox]]]]]) #|> IO.inspect
  end

  # TODO: does not take permissions into consideration
  def preload_creator(object),
    do: Bonfire.Repo.preload(object, [created: [creator: [character: [:inbox]]]])

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
