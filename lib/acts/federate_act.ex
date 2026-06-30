defmodule Bonfire.Social.Acts.Federate do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that translates an object (eg. a post) or changeset into some jobs for the AP publish worker. Handles creation, update and delete.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `ap_on` - key in assigns to find the AP object, default: `:ap_object`
    * `action` - indicates what kind of action we're federating, default: `:insert`
    * `current_user` - self explanatory
  """

  use Arrows
  import Bonfire.Epics
  import Untangle
  use Bonfire.Common.E

  # alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Common.Utils
  alias Bonfire.Common.Enums
  # alias Bonfire.Data.Social.Post
  alias Bonfire.Social
  # alias Ecto.Changeset
  alias Bonfire.Common
  # alias Common.Types

  def run(epic, act) do
    # epic.assigns
    # |> IO.inspect(label: "eppppic asss")

    on = Keyword.get(act.options, :on, :post)
    ap_on = Keyword.get(act.options, :ap_on, :ap_object)
    options = epic.assigns[:options]
    action = Keyword.get(options, :action, :insert)
    current_user = Utils.current_user_or_id(options)
    object = epic.assigns[on]

    # resolve the object's creator locality once here and pass it along (via `Epic.assign(on, ...)` at the end of run/2), so the `is_local?(object)` check below — and later acts — classify without an N+1 per-build preload
    debug(object, "FEDERATE_DEBUG object BEFORE resolve")

    object =
      case object do
        %{} = object ->
          if is_struct(current_user) and
               e(object, :created, :creator_id, nil) == Enums.id(current_user) do
            # the object was just created by current_user, so carry their already locality-marked struct in for free
            put_in(object.created.creator, current_user)
            |> debug("FEDERATE_DEBUG object AFTER put_in")
          else
            # boost/reply/delete of someone else's object: preload its locality once — the object's
            # own `character.peered` (e.g. a user being deleted) and/or its `created.creator`'s
            object
            |> Social.repo().maybe_preload(created: [creator: [character: [:peered]]])
            |> Social.repo().maybe_preload(
              #  in case it is a Category or such
              character: [:peered]
            )
            |> debug("FEDERATE_DEBUG object AFTER maybe_preload")
          end

        object ->
          object
      end

    debug(
      %{
        action: action,
        current_user:
          {Enums.id(current_user), e(current_user, :peered, :MISSING),
           e(current_user, :character, :peered, :MISSING)},
        object:
          {Enums.id(object), e(object, :peered, :MISSING),
           e(object, :character, :peered, :MISSING),
           e(object, :created, :creator, :peered, :MISSING)}
      },
      "FEDERATE_DEBUG id / peered / character.peered / created.creator.peered"
    )

    debug(current_user, "FEDERATE_DEBUG full current_user")
    debug(object, "FEDERATE_DEBUG full object")
    # current_user_id = Types.uid(current_user)

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

      is_nil(object) ->
        warn(current_user, "ActivityPub: Skipping due to missing object")
        nil

      # not is_binary(current_user_id) ->
      #   warn(current_user, "ActivityPub: Skipping due to missing current_user")
      #   nil

      options[:skip_federation] ->
        info("ActivityPub: skip_federation was set")

        # do this anyway because we might need to create pending quote requests for local objects
        maybe_create_pending_quote_requests(
          current_user,
          epic.assigns[:request_quotes],
          object,
          options
        )

        nil

      Social.federate_outgoing?(current_user) != true ->
        info(
          "ActivityPub: Federation is disabled (possibly just for this user) or an adapter is not available"
        )

        # do this anyway because we might need to create pending quote requests for local objects
        maybe_create_pending_quote_requests(
          current_user,
          epic.assigns[:request_quotes],
          object,
          options
        )

        nil

      not Social.is_local?(current_user) or
          not Social.is_local?(object) ->
        warn(current_user, "ActivityPub: Skip pushing remote object")

        # should we do this here?
        # maybe_create_pending_quote_requests(
        #   current_user,
        #   epic.assigns[:request_quotes],
        #   object,
        #   options
        # )

        nil

      action in [:insert] ->
        maybe_debug(epic, act, action, "Maybe queue for federation")

        with {:ok, result} <-
               Bonfire.Social.maybe_federate_and_gift_wrap_activity(
                 current_user,
                 object,
                 options ++
                   [
                     ap_object: epic.assigns[ap_on],
                     ap_bcc: epic.assigns[:ap_bcc]
                   ]
               ) do
          maybe_create_pending_quote_requests(
            current_user,
            epic.assigns[:request_quotes],
            object,
            options
          )

          # return federation result
          {:ok, result}
        end

      action in [:update] ->
        maybe_debug(epic, act, action, "Maybe queue update for federation")

        with {:ok, result} <-
               Bonfire.Social.maybe_federate_and_gift_wrap_activity(
                 current_user,
                 object,
                 options ++
                   [
                     verb: :update,
                     ap_object: epic.assigns[ap_on],
                     ap_bcc: epic.assigns[:ap_bcc]
                   ]
               ) do
          maybe_create_pending_quote_requests(
            current_user,
            epic.assigns[:request_quotes],
            object,
            options
          )

          # return federation result
          {:ok, result}
        end

      # WIP: deletion
      action == :delete ->
        maybe_debug(epic, act, action, "Maybe queue delete for federation")

        # debug(epic.assigns[ap_on], "ap_on")

        Bonfire.Social.maybe_federate_and_gift_wrap_activity(
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
    |> Epic.assign(epic, on, from_ok(...) || object)
  end

  defp maybe_create_pending_quote_requests(
         current_user,
         request_quotes,
         object,
         options
       ) do
    if request_quotes && Bonfire.Common.Extend.module_enabled?(Bonfire.Social.Quotes) do
      Bonfire.Social.Quotes.create_quote_requests(
        current_user,
        request_quotes,
        object,
        options
      )
    end
  end
end
