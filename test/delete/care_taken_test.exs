defmodule Bonfire.Social.CareTakenTest do
  @moduledoc """
  Unit coverage for the caretaker sweep that user deletion depends on.

  `Users.delete/2` passes `delete_caretaken: true`, so deleting a user runs `Objects.care_taken/1`
  and then `do_delete/2` over everything they caretake — their ACLs, circles and feeds. In CI
  (`dance/delete_user_dance_test.exs:23`) that sweep reaches `try_generic_delete/4` on a
  `Bonfire.Data.AccessControl.Acl` and dies with a Postgres `operator does not exist: text | uuid`,
  rolling the whole delete transaction back so the user is never removed.

  These exercise the sweep directly rather than trying to recreate the full federated scenario.
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.Objects
  alias Bonfire.Me.Fake

  describe "care_taken/1" do
    test "returns the objects a user is caretaker of" do
      user = Fake.fake_user!()

      caretaken = Objects.care_taken([id(user)])

      assert is_list(caretaken)

      refute Enum.any?(caretaken, &(id(&1) == id(user))),
             "the user themselves is not something they caretake"
    end

    test "returns nothing for an id that caretakes nothing" do
      assert [] = Objects.care_taken([Needle.UID.generate()])
    end
  end

  describe "deleting what a user caretakes" do
    # The sweep that `delete_caretaken: true` performs. If any object in it cannot be deleted, the
    # surrounding transaction rolls back and the USER survives — which is the CI symptom.
    test "every caretaken object can be deleted without erroring" do
      user = Fake.fake_user!()

      caretaken = Objects.care_taken([id(user)])

      for object <- caretaken do
        assert Objects.do_delete(object, skip_boundary_check: true, skip_federation: true),
               "failed to delete a #{inspect(Bonfire.Common.Types.object_type(object))} that #{id(user)} caretakes"
      end
    end

    test "delete_caretaken/1 completes for a plain user" do
      user = Fake.fake_user!()

      assert Objects.delete_caretaken(user)
    end
  end

  describe "try_generic_delete/4 on schemas with no context module" do
    # `Bonfire.Data.AccessControl.Acl` declares no `context_module/0`, so deleting one always falls
    # through to generic deletion — the exact path that errors in CI.
    test "an Acl can be deleted generically" do
      user = Fake.fake_user!()

      acl =
        Objects.care_taken([id(user)])
        |> Enum.find(&match?(%Bonfire.Data.AccessControl.Acl{}, &1))

      if acl do
        assert Objects.maybe_generic_delete(Bonfire.Data.AccessControl.Acl, acl,
                 skip_boundary_check: true,
                 skip_federation: true
               )
      end
    end

    # Which creation path produces a user that caretakes Acls decides whether the CI failure is
    # reachable locally at all: `delete_caretaken: true` only reaches `try_generic_delete` if there
    # is something to sweep.
    test "what a user caretakes, by creation path" do
      faked = Objects.care_taken([id(Fake.fake_user!())])

      {:ok, account} = Bonfire.Me.Accounts.signup(Bonfire.Me.Fake.Helpers.signup_form())

      {:ok, signed_up} =
        Bonfire.Me.Users.create(Bonfire.Me.Fake.Helpers.create_user_form(), account)

      real = Objects.care_taken([id(signed_up)])

      types = fn objects ->
        objects |> Enum.map(&Bonfire.Common.Types.object_type/1) |> Enum.frequencies()
      end

      assert types.(faked) == types.(real),
             "fake_user! and the real signup path should produce the same caretaken set, otherwise tests using fake_user! cannot exercise deletion faithfully — faked: #{inspect(types.(faked))} vs signed up: #{inspect(types.(real))}"
    end
  end
end
