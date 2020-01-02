defmodule Tzinfo.Posix do
  @moduledoc """
  Parser for POSIX compatible and ascii encoded timezone strings.

  See the following resources for more details:

  * https://pubs.opengroup.org/onlinepubs/9699919799/
  * https://developer.ibm.com/articles/au-aix-posix/
  * https://tools.ietf.org/html/rfc8536#section-3.3
  """
  import NimbleParsec

  @type abbr :: String.t()
  @type offset :: integer()
  @type julian_one_based :: %{
          midnight_offset: offset(),
          type: :julian_one_based,
          value: pos_integer()
        }
  @type julian_zero_based :: %{
          midnight_offset: offset(),
          type: :julian_zero_based,
          value: non_neg_integer()
        }
  @type month_based :: %{
          midnight_offset: offset(),
          type: :month_based,
          value: %{day: non_neg_integer(), month: pos_integer(), week: pos_integer()}
        }
  @type point_in_year :: julian_one_based() | julian_zero_based() | month_based()
  @type std :: %{abbr: abbr(), utc_offset: offset(), std_offset: offset()}
  @type dst :: %{
          abbr: abbr(),
          utc_offset: offset(),
          std_offset: offset(),
          start: :undefined | point_in_year(),
          end: :undefined | point_in_year()
        }
  @type t :: %{std: :none | std(), dst: :none | dst()}

  # e.g. CST
  alpha_abbr = ascii_string([?A..?Z, ?a..?z], min: 3, max: 6)

  # e.g. <-09>
  quoted_abbr =
    ignore(ascii_char([?<]))
    |> repeat(ascii_char([?A..?Z, ?a..?z, ?0..?9, ?+, ?-]))
    |> ignore(ascii_char([?>]))
    |> wrap()
    |> map({List, :to_string, []})

  abbr = choice([alpha_abbr, quoted_abbr])

  one_digit_integer = ascii_char([?0..?9])
  two_digit_integer = times(ascii_char([?0..?9]), 2)
  three_digit_integer = times(ascii_char([?0..?9]), 3)

  one_or_two_digit_integer = choice([two_digit_integer, one_digit_integer])

  one_two_or_three_digit_integer =
    choice([three_digit_integer, two_digit_integer, one_digit_integer])

  # e.g. 4, 4:00, 4:00:00, 04:00:00
  time_combinator =
    wrap(one_two_or_three_digit_integer)
    |> map(:to_integer)
    |> unwrap_and_tag(:hours)
    |> optional(
      ignore(ascii_char([?:]))
      |> wrap(two_digit_integer)
      |> map(:to_integer)
      |> unwrap_and_tag(:minutes)
    )
    |> optional(
      ignore(ascii_char([?:]))
      |> wrap(two_digit_integer)
      |> map(:to_integer)
      |> unwrap_and_tag(:seconds)
    )

  # like time_combinator, but signed and with three digits for hours
  time_combinator_extended =
    wrap(one_two_or_three_digit_integer)
    |> map(:to_integer)
    |> unwrap_and_tag(:hours)
    |> optional(
      ignore(ascii_char([?:]))
      |> wrap(two_digit_integer)
      |> map(:to_integer)
      |> unwrap_and_tag(:minutes)
    )
    |> optional(
      ignore(ascii_char([?:]))
      |> wrap(two_digit_integer)
      |> map(:to_integer)
      |> unwrap_and_tag(:seconds)
    )

  offset =
    optional(ascii_char([?+, ?-]) |> unwrap_and_tag(:sign))
    |> concat(time_combinator)
    |> wrap()
    |> map(:to_offset)

  offset_extended =
    optional(ascii_char([?+, ?-]) |> unwrap_and_tag(:sign))
    |> concat(time_combinator_extended)
    |> post_traverse(:to_offset)

  abbr_and_req_offset =
    abbr
    |> concat(offset)
    |> wrap()
    |> map({:to_abbr_offset_tuple, [:utc_offset]})

  abbr_and_opt_offset =
    abbr
    |> optional(offset)
    |> wrap()
    |> map({:to_abbr_offset_tuple, [:std_offset]})

  julian_one_based =
    ignore(ascii_char([?J]))
    |> concat(one_two_or_three_digit_integer)
    |> wrap()
    |> map(:to_integer)
    |> map(:julian_one_based)
    |> unwrap_and_tag(:julian_one_based)

  julian_zero_based =
    one_two_or_three_digit_integer
    |> wrap()
    |> map(:to_integer)
    |> map(:julian_zero_based)
    |> unwrap_and_tag(:julian_zero_based)

  month_based =
    ignore(ascii_char([?M]))
    |> concat(one_or_two_digit_integer |> wrap() |> map(:to_integer))
    |> ignore(ascii_char([?.]))
    |> concat(one_digit_integer |> wrap() |> map(:to_integer))
    |> ignore(ascii_char([?.]))
    |> concat(one_digit_integer |> wrap() |> map(:to_integer))
    |> wrap()
    |> map(:month_based_values)
    |> unwrap_and_tag(:month_based)

  date =
    choice([
      month_based,
      julian_one_based,
      julian_zero_based
    ])

  rule =
    date
    |> optional(
      ignore(ascii_char([?/]))
      |> concat(offset_extended)
    )
    |> wrap()
    |> map(:move_tag)

  defparsecp(
    :do_parse,
    abbr_and_req_offset
    |> unwrap_and_tag(:std)
    |> optional(
      abbr_and_opt_offset
      |> optional(
        ignore(ascii_char([?,]))
        |> concat(rule)
        |> unwrap_and_tag(:start)
        |> concat(
          ignore(ascii_char([?,]))
          |> concat(rule)
          |> unwrap_and_tag(:end)
        )
      )
      |> wrap()
      |> map(:to_dst_map)
      |> unwrap_and_tag(:dst)
    )
    |> post_traverse(:transform)
    |> eos()
  )

  @doc """
  Parser for POSIX compatible and ascii encoded timezone strings.

  Does also support certain extentions, which might not be POSIX compatible:

  * `:extended_transition_offset`. When enabled it allows start/end time offsets
  to be signed and have the hour range from `-167..167`. This must be allowed in strings
  coming from zonefiles of version 3.

  ## Examples

      iex> parse("HST10")
      {:ok, %{std: %{abbr: "HST", utc_offset: 36000, std_offset: 0}, dst: :none}}

      iex> parse("CST6CDT,M3.2.0/2:00:00,M11.1.0/2:00:00")
      {:ok,
        %{
          std: %{abbr: "CST", utc_offset: 21600, std_offset: 0},
          dst: %{
            abbr: "CDT",
            utc_offset: 21600,
            std_offset: 3600,
            start: %{
              midnight_offset: 7200,
              type: :month_based,
              value: %{day: 0, month: 3, week: 2}
            },
            end: %{
              midnight_offset: 7200,
              type: :month_based,
              value: %{day: 0, month: 11, week: 1}
            }
          }
        }}

      iex> parse("<-03>3<-02>,M3.5.0/-1,M10.5.0/-2", extended_transition_offset: true)
      {:ok,
        %{
          std: %{abbr: "-03", utc_offset: 10800, std_offset: 0},
          dst: %{
            abbr: "-02",
            utc_offset: 10800,
            std_offset: 3600,
            start: %{
              midnight_offset: -3600,
              type: :month_based,
              value: %{day: 0, month: 3, week: 5}
            },
            end: %{
              midnight_offset: -7200,
              type: :month_based,
              value: %{day: 0, month: 10, week: 5}
            }
          }
        }}
  """
  @spec parse(String.t()) :: {:ok, t} | {:error, String.t()}
  @spec parse(String.t(), Keyword.t()) :: {:ok, t} | {:error, String.t()}
  def parse(str, opts \\ []) do
    try do
      case do_parse(str, context: opts) do
        {:ok, [result], _, _, _, _} ->
          {:ok, result}

        {:error, err, rest, _context, {line, column}, _byte_offset} ->
          {:error, "Error at (#{line}:#{column}) of '#{rest}': #{err}"}
      end
    catch
      err -> {:error, err}
    end
  end

  defp to_integer(chars) do
    List.to_integer(chars, 10)
  end

  defp to_offset(_rest, values, context, _line, _offset) do
    offset = values |> Enum.reverse() |> to_offset()

    case {offset, context} do
      {x, %{extended_transition_offset: true}} when abs(x) < 168 * 3600 ->
        :ok

      {x, _} when x >= 0 and x < 25 * 3600 ->
        :ok

      {offset, _} ->
        throw("Invalid offset #{offset} for #{inspect(values)}")
    end

    {List.wrap(offset), context}
  end

  defp to_offset([{:sign, ?+} | rest]) do
    to_offset(rest)
  end

  defp to_offset([{:sign, ?-} | rest]) do
    -1 * to_offset(rest)
  end

  defp to_offset(hours: x) when x in 0..167 do
    x * 3600
  end

  defp to_offset(hours: x, minutes: y) when y in 0..59 do
    to_offset(hours: x) + y * 60
  end

  defp to_offset(hours: x, minutes: y, seconds: z) when z in 0..59 do
    to_offset(hours: x, minutes: y) + z
  end

  defp to_abbr_offset_tuple([abbr], offset_key) do
    to_abbr_offset_tuple([abbr, :default], offset_key)
  end

  defp to_abbr_offset_tuple([abbr, offset], offset_key) do
    %{}
    |> Map.put(:abbr, abbr)
    |> Map.put(offset_key, offset)
  end

  defp move_tag([{tag, value}]),
    do: %{
      type: tag,
      value: value,
      midnight_offset: Time.diff(~T[02:00:00], ~T[00:00:00], :second)
    }

  defp move_tag([{tag, value}, offset]),
    do: %{type: tag, value: value, midnight_offset: offset}

  defp month_based_values([m, n, d]) when m in 1..12 and n in 1..5 and d in 0..6 do
    %{
      month: m,
      week: n,
      day: d
    }
  end

  defp month_based_values(_), do: :invalid

  defp julian_one_based(n) when n in 1..365, do: n
  defp julian_one_based(_), do: :invalid

  defp julian_zero_based(n) when n in 0..365, do: n
  defp julian_zero_based(_), do: :invalid

  defp to_dst_map([x]) do
    x
    |> Map.put(:start, :undefined)
    |> Map.put(:end, :undefined)
  end

  defp to_dst_map([x, start: start, end: stop]) do
    x
    |> Map.put(:start, start)
    |> Map.put(:end, stop)
  end

  defp transform(_, [std: std], context, _, _),
    do: {[%{std: Map.put(std, :std_offset, 0), dst: :none}], context}

  defp transform(_, [dst: dst, std: std], context, _, _) do
    value = %{
      std: Map.put(std, :std_offset, 0),
      dst:
        dst
        |> Map.update!(:std_offset, fn
          :default -> 3600
          offset -> offset - std.utc_offset
        end)
        |> Map.put(:utc_offset, std.utc_offset)
    }

    value =
      if Map.get(context, :all_year_dst, false) && dst_all_year?(value.dst) do
        %{value | std: :none}
      else
        value
      end

    {[value], context}
  end

  defp dst_all_year?(%{
         std_offset: std_offset,
         start: %{type: :julian_zero_based, value: 0, midnight_offset: 0},
         end: %{type: :julian_one_based, value: 365, midnight_offset: end_offset}
       }) do
    end_offset_at_year_end?(std_offset, end_offset)
  end

  defp dst_all_year?(%{
         std_offset: std_offset,
         start: %{type: :julian_one_based, value: 1, midnight_offset: 0},
         end: %{type: :julian_one_based, value: 365, midnight_offset: end_offset}
       }) do
    end_offset_at_year_end?(std_offset, end_offset)
  end

  defp dst_all_year?(_), do: false

  defp end_offset_at_year_end?(std_offset, end_offset) do
    24 * 3600 + std_offset <= end_offset
  end
end
