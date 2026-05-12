defmodule Smithy do
  @moduledoc """
  Smithy is the thin supervisor + CLI for managing N Symphony daemons across N repos.

  See `v2/SPEC.md` § "Smithy wrapper" for the full design. This module exposes
  version metadata. All real work lives in the submodules.
  """

  @version Mix.Project.config()[:version] || "0.1.0"

  @spec version() :: String.t()
  def version, do: @version
end
