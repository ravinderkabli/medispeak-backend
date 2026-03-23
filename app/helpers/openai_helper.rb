require "net/http"

module OpenaiHelper
  def client
    validate_api_credentials
    @client ||= OpenAI::Client.new(
      access_token: ENV["OPENAI_ACCESS_TOKEN"],
      organization_id: ENV["OPENAI_ORGANIZATION_ID"]
    )
  end

  def ai_transcribe(file)
    begin
      response = client.audio.translate(parameters: { model: "whisper-1", file: File.open(file) })
      response["text"]
    rescue Faraday::Error => e
      handle_openai_error(e)
    end
  end

  def system_prompt(transcription)
    return transcription.page.prompt if transcription.page.prompt.present?

    "You are an AI assistant filling the form for a user. Make sure that you do not populate the form with any data that the user did not provide. Ensure all data shared by users are correctly split into function arguments."
  end

  def ai_generate_completion(transcription)
    validate_claude_credentials

    # Claude requires property keys matching ^[a-zA-Z0-9_.-]{1,64}$
    # Build sanitized_key → original_title mapping so we can restore original keys from the response
    key_map = {}
    transcription.form_fields.each do |f|
      key_map[sanitize_field_key(f.title)] = f.title
    end

    properties = claude_properties(transcription.form_fields, transcription.context)

    uri = URI("https://api.anthropic.com/v1/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request["x-api-key"] = ENV["ANTHROPIC_API_KEY"]
    request["anthropic-version"] = "2023-06-01"
    request["content-type"] = "application/json"
    request.body = {
      model: "claude-opus-4-6",
      max_tokens: 1024,
      system: system_prompt(transcription),
      messages: [
        { role: "user", content: transcription.transcription_text }
      ],
      tools: [
        {
          name: "fill_form",
          description: "Fill out a form with the data from the user's message",
          input_schema: {
            type: "object",
            properties: properties,
            required: []
          }
        }
      ],
      tool_choice: { type: "auto" }
    }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)

    unless response.code.to_i == 200
      raise GenericException.new(
        message: "Claude API error: #{body.dig("error", "message") || response.message}",
        code: :failed_dependency
      )
    end

    usage = body["usage"]
    tool_use = body["content"]&.find { |c| c["type"] == "tool_use" }

    if tool_use && tool_use["name"] == "fill_form"
      # Restore original field titles from sanitized keys
      args = tool_use["input"].transform_keys { |k| (key_map[k] || k).to_sym }
      transcription.update!(
        ai_response: args,
        status: :completion_generated,
        prompt_tokens: (usage["input_tokens"] || 0) + transcription.prompt_tokens,
        completion_tokens: (usage["output_tokens"] || 0) + transcription.completion_tokens,
        total_tokens: ((usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)) + transcription.total_tokens
      )
    else
      transcription.update!(status: :failed)
    end
  end

  def smart_description(form_field, context)
    base_description = form_field.description.presence || form_field.friendly_name
    context_info = context[form_field.title] if context.present?

    [ base_description, context_info ].compact.join("; Context: ")
  end

  def create_types_form_form_fields(form_fields, context)
    fields = {}
    form_fields.each do |form_field|
      fields[form_field.title] = form_field.to_json_schema_for_ai.merge(
        description: smart_description(form_field, context)
      )
    end
    fields
  end

  private

  def sanitize_field_key(title)
    title.to_s.gsub(/[^a-zA-Z0-9_.\-]/, "_").slice(0, 64)
  end

  # Like create_types_form_form_fields but uses sanitized keys for Claude
  def claude_properties(form_fields, context)
    fields = {}
    form_fields.each do |form_field|
      fields[sanitize_field_key(form_field.title)] = form_field.to_json_schema_for_ai.merge(
        description: smart_description(form_field, context)
      )
    end
    fields
  end

  def validate_api_credentials
    unless ENV["OPENAI_ACCESS_TOKEN"].present?
      raise GenericException.new(
        message: "OpenAI API key is missing. Please set it in the environment variable OPENAI_ACCESS_TOKEN.",
        code: :failed_dependency
      )
    end
  end

  def validate_claude_credentials
    unless ENV["ANTHROPIC_API_KEY"].present?
      raise GenericException.new(
        message: "Anthropic API key is missing. Please set ANTHROPIC_API_KEY.",
        code: :failed_dependency
      )
    end
  end

  def handle_openai_error(error)
    raise GenericException.new(
        message: "The OpenAI request was unsuccessful. " \
          "Please verify your API key, organization ID, plan, " \
          "and billing details before attempting again. Error: #{error.message}",
        code: :failed_dependency
      )
  end
end
