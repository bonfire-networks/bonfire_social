defmodule Bonfire.Social.Import.InstanceWideImportTest do
  @moduledoc "An import job an instance admin queued for the whole instance (its `user_id` is `instance_wide`) applies there: nobody acts when it runs, so it is a system path."
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Common.Import

  @moduletag :backend

  defp run_job(op, user) do
    Import.perform(%{
      args: %{
        "op" => op,
        "user_id" => "instance_wide",
        "identifier" => Bonfire.Me.Characters.character_url(user)
      }
    })
  end

  test "an instance-wide silences import silences the account for everyone" do
    user = fake_user!()

    refute Blocks.is_blocked?(user, :silence, :instance_wide),
           "control: not silenced to begin with"

    assert :ok = run_job("silences_import", user)

    assert Blocks.is_blocked?(user, :silence, :instance_wide)
  end

  test "an instance-wide ghosts import ghosts the account for everyone" do
    user = fake_user!()

    assert :ok = run_job("ghosts_import", user)

    assert Blocks.is_blocked?(user, :ghost, :instance_wide)
  end
end
