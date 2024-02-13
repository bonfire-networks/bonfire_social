defmodule Bonfire.Social.Acts.Federate do
  @moduledoc """

  An Act that translates a post or changeset into some jobs for the
  AP publish worker. Handles creation, update and delete

  Act Options:
    * `on` - key in assigns to find the post, default: `:post`
    * `as` - key in assigns to assign indexable object, default: `:post_index`
  """
  use Arrows
  import Bonfire.Epics
  import Untangle

  # alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Post
  alias Bonfire.Social.Integration
  # alias Ecto.Changeset
  alias Bonfire.Common
  alias Common.Types

  def run(epic, act) do
    # epic.assigns
    # |> IO.inspect(label: "eppppic asss")

    on = Keyword.get(act.options, :on, :post)
    ap_on = Keyword.get(act.options, :ap_on, :ap_object)
    object = epic.assigns[on]
    options = epic.assigns[:options]
    action = Keyword.get(options, :action, :insert)
    current_user = options[:current_user]
    current_user_id = Types.ulid(current_user)

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "ActivityPub: Skipping due to epic errors"
        )

        nil

      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "ActivityPub: Skipping due to `on` option")
        nil

      # not is_binary(current_user_id) ->
      #   warn(current_user, "ActivityPub: Skipping due to missing current_user")
      #   nil

      options[:skip_federation] ->
        info("ActivityPub: skip_federation was set")

        nil

      Integration.federate_outgoing?(current_user) != true ->
        info(
          "ActivityPub: Federation is disabled (possibly just for this user) or an adapter is not available"
        )

        nil

      not Integration.is_local?(current_user) or not Integration.is_local?(object) ->
        warn(current_user, "ActivityPub: Skip pushing remote object")
        nil

      action in [:insert] ->
        maybe_debug(epic, act, action, "Maybe queue for federation")

        Bonfire.Social.Integration.maybe_federate_and_gift_wrap_activity(
          current_user,
          object,
          options
        )

      action in [:update] ->
        maybe_debug(epic, act, action, "Maybe queue update for federation")

        Bonfire.Social.Integration.maybe_federate_and_gift_wrap_activity(
          current_user,
          object,
          options ++
            [verb: :update, ap_object: epic.assigns[ap_on], ap_bcc: epic.assigns[:ap_bcc]]
        )

      # TODO: deletion
      action == :delete ->
        maybe_debug(epic, act, action, "Maybe queue delete for federation")

        Bonfire.Social.Integration.maybe_federate_and_gift_wrap_activity(
          current_user,
          object,
          options ++
            [verb: :delete, ap_object: epic.assigns[ap_on], ap_bcc: epic.assigns[:ap_bcc]]
        )

      true ->
        maybe_debug(
          epic,
          act,
          action,
          "ActivityPub: Skipping due to unknown action"
        )

        nil
    end
    |> Epic.assign(epic, on, Utils.ok_unwrap(...) || object)
  end
end
