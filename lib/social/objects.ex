defmodule Bonfire.Social.Objects do

  use Bonfire.Repo,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]

  alias Bonfire.Social.Activities
  alias Bonfire.{Common, Common.Utils}

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

  # when the user picks a preset, this maps to a set of base acls
  defp preset_acls("public"), do: Enum.map([:guests_may_see, :locals_may_reply], &Acls.get_id!/1)
  defp preset_acls("mentions"), do: []
  defp preset_acls("local"), do: Enum.map([:locals_may_reply], &Acls.get_id!/1)

  # def doing(attrs, preset) do
    # we need to handle: replies (threads), tags, mentions
    # if we see an attempted reply, we load it and verify whether you are permitted to do that.
    # if we see tags, we load them and verify you are permitted to use them
    
  #   acls = preset_acls(preset)
  #   tags = maybe_load_tags(object, preset)
  #   feeds = reply_to_inboxes(object, subject, preset) ++ tag_inboxes(tags)
  #   tag_ids = Enum.map(tags, &(&1.id))
  #   with {:ok, activity} <- do_pub(subject, verb, object, circles) do
  #     # maybe_make_visible_for(subject, object, circles ++ tag_ids(tags))
  #     Threads.maybe_push_thread(subject, activity, object)
  #     notify_inboxes(subject, activity, object, feeds)
  #   end

  # end
          
  # # TODO: modernise tags so we can do this in one query
  # def maybe_load_tags(%{tags: tags=[_|_]}, yes)
  # when yes in ["public", "mentions"], do: Repo.preload(Bonfire.Tags.Tags.many(), [character: [:inbox]])
  # def maybe_load_tags(_, _), do: []

  # # used for public and mentions presets. returns a list of feed ids
  # defp tag_inboxes(tags) when is_list(tags), do: Enum.flat_map(tags, &tag_inboxes/1)
  # defp tag_inboxes(%{character: %Character{inbox: %Inbox{feed_id: id}}})
  # when not is_nil(id), do: [id]
  # defp tag_inboxes(_), do: []

  # # used for public preset. if the creator is me, the empty list, else a list of one feed id
  # defp reply_to_inboxes(object, %{id: me}, "public") do
  #   case object do
  #     %{created: %{creator_id: creator}
  #       replied: %{reply_to: %{character: %{inbox: %{feed_id: feed}}}}}
  #     when not is_nil(feed) and not is_nil(creator) and creator == me  -> [feed]
  #     _ -> []
  #   end
  # end
  # defp reply_to_inboxes(_, _, _), do: []

  
end
