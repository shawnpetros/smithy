defmodule Smithy.Color do
  @moduledoc """
  Deterministic per-repo accent colors from slug hashes.

  Both the web dashboard and TUI derive colors from the same function
  so the accent for a given slug is consistent across surfaces.
  """

  @doc """
  Returns a stable hue (0-359) for a repo slug via MD5 first-byte.
  """
  @spec slug_hue(String.t()) :: 0..359
  def slug_hue(slug) when is_binary(slug) do
    <<first, _::binary>> = :crypto.hash(:md5, slug)
    div(first * 359, 255)
  end

  @doc """
  Returns an ANSI 256-color foreground escape for use in the TUI.
  Uses a saturated color from the xterm-256 6x6x6 cube (indices 16-231).
  """
  @spec slug_ansi_256(String.t()) :: String.t()
  def slug_ansi_256(slug) when is_binary(slug) do
    code = slug |> slug_hue() |> hue_to_ansi_256()
    "\e[38;5;#{code}m"
  end

  @doc """
  Returns the CSS HSL hue integer for use in `hsl(H, S%, L%)` expressions.
  Same value as `slug_hue/1` - a distinct name for clarity in CSS contexts.
  """
  @spec slug_css_hue(String.t()) :: 0..359
  def slug_css_hue(slug), do: slug_hue(slug)

  # Maps hue 0-359 to the nearest saturated color in the xterm-256 6x6x6 cube.
  # Cube formula: index = 16 + 36*r + 6*g + b where r,g,b ∈ 0..5.
  defp hue_to_ansi_256(hue) do
    sector = div(hue, 60)
    ramp = div(rem(hue, 60) * 5, 59)

    {r, g, b} =
      case sector do
        0 -> {5, ramp, 0}
        1 -> {5 - ramp, 5, 0}
        2 -> {0, 5, ramp}
        3 -> {0, 5 - ramp, 5}
        4 -> {ramp, 0, 5}
        _ -> {5, 0, 5 - ramp}
      end

    16 + 36 * r + 6 * g + b
  end
end
