class AskQuestionJob
  include Sidekiq::Job

  def perform(conversation_id, reply_id)
    conversation = Conversation.find(conversation_id)
    return if conversation.nil?

    reply = Message.find(reply_id)
    openai = OpenAI::Client.new(access_token: ENV['OPENAI_ACCESS_TOKEN'])
    viability = determine_viability(openai, conversation)

    if !viability["content_contains_answer"]
      handle_non_viable_conversation(openai, conversation, reply, viability)
    else
      generate_response_content(openai, conversation, reply)
    end
  end

  private

  def handle_non_viable_conversation(openai, conversation, reply, viability)
    if viability["user_intent"] == "system"
      reply.update(content: "I'm sorry, I'm not able to help with that right now.")
      update_conversation(reply, conversation)
    else
      reply.update(status: 'data')
      update_conversation(reply, conversation)

      build_sql(openai, conversation, viability["user_intent"])
      viability = determine_viability(openai, conversation)

      if viability["content_contains_answer"]
        reply.update(status: 'processing')
        update_conversation(reply, conversation)

        generate_response_content(openai, conversation, reply)
      else
        reply.update(content: "I'm sorry, I wasn't able to find the necessary information in the database.")
        update_conversation(reply, conversation)
      end
    end
  end

  def generate_response_content(openai, conversation, reply)
    response_content = query_openai(openai, conversation, reply)
    reply.update(content: response_content, status: 'done')
    update_conversation(reply, conversation)
  end

  def update_conversation(reply, conversation)
    conversation.broadcast_append_to "conversation_area", partial: "conversations/message", locals: { message: reply }, target: "conversation_area_#{conversation.id}"
  end

  def build_sql(openai, conversation, sql_intent)
    # Load schema file from config/llmschema.yml
    schema = YAML.load_file(Rails.root.join('config', 'llmschema.yml'))
    sql_scopes = YAML.load_file(Rails.root.join('config', 'llmsql.yml'))
    scope = sql_scopes['intent'].find { |intent| intent['name'] == sql_intent }['scope']
    core = sql_scopes['core'].first['scope']

    family_id = conversation.user.family_id
    accounts_ids = conversation.user.accounts.pluck(:id)

    # Get the most recent user message
    message = conversation.messages.where(role: "user").order(created_at: :asc).last

    # Get the last log message from the assistant and get the 'resolve' value (log should be converted to a hash from JSON)
    last_log = conversation.messages.where(role: "log").where.not(log: nil).order(created_at: :desc).first
    last_log_json = JSON.parse(last_log.log)
    resolve_value = last_log_json["resolve"]

    sql = openai.chat(
      parameters: {
        model: "gpt-4-1106-preview",
        messages: [
          { role: "system", content: "You are an expert in SQL and Postgres."},
          { role: "assistant", content: <<-ASSISTANT.strip_heredoc },
            #{schema}

            family_id = #{family_id}
            account_ids = #{accounts_ids}

            Given the preceding Postgres database schemas and variables, write an SQL query that answers the question '#{message.content}'.

            According to the last log message, this is what is needed to answer the question: '#{resolve_value}'.

            Scope:
            #{core}
            #{scope}

            Respond exclusively with the SQL query, no preamble or explanation, beginning with 'SELECT' and ending with a semicolon.

            Do NOT include "```sql" or "```" in your response.
          ASSISTANT
        ],
        temperature: 0,
        max_tokens: 2048
      }
    )

    sql_content = sql.dig("choices", 0, "message", "content")

    markdown_reply = conversation.messages.new
    markdown_reply.log = sql_content
    markdown_reply.user = nil
    markdown_reply.role = "assistant"
    markdown_reply.hidden = true
    markdown_reply.save

    Rails.logger.warn sql_content

    results = ReplicaQueryService.execute(sql_content)

    # Convert results to markdown
    markdown = "| #{results.fields.join(' | ')} |\n| #{results.fields.map { |f| '-' * f.length }.join(' | ')} |\n"
    results.each do |row|
      markdown << "| #{row.values.join(' | ')} |\n"
    end

    if results.first.nil?
      response_content = "I wasn't able to find any relevant information in the database."
      markdown_reply.update(content: response_content)
    else
      markdown_reply.update(content: markdown)
    end
  end

  def determine_viability(openai, conversation)
    conversation_history = conversation.messages.where.not(content: [nil, ""]).where.not(content: "...").where.not(role: 'log').order(:created_at)

    messages = conversation_history.map do |message|
      { role: message.role, content: message.content }
    end

    total_content_length = messages.sum { |message| message[:content]&.length.to_i }

    while total_content_length > 10000
      oldest_message = messages.shift
      total_content_length -= oldest_message[:content]&.length.to_i

      if total_content_length <= 8000
        messages.unshift(oldest_message) # Put the message back if the total length is within the limit
        break
      end
    end

    # Remove the last message, as it is the one we are trying to answer
    messages.pop if messages.last[:role] == "user"

    message = conversation.messages.where(role: "user").order(created_at: :asc).last

    response = openai.chat(
      parameters: {
        model: "gpt-4-1106-preview",
        messages: [
          { role: "system", content: "You are a highly intelligent certified financial advisor tasked with helping the customer make wise financial decisions based on real data.\n\nHere's some contextual information:\n#{messages}"},
          { role: "assistant", content: <<-ASSISTANT.strip_heredoc },
            Instructions: First, determine the user's intent from the following prioritized list:
            1. reply: the user is replying to a previous message
            2. education: the user is trying to learn more about personal finance, but is not asking specific questions about their own finances
            3. metrics: the user wants to know the value of specific financial metrics (we already have metrics for net worth, depository balance, investment balance, total assets, total debts, and categorical spending). does NOT include merchant-specific metrics. for example, you will NOT find Amazon spending, but you will find all spending in the 'shopping' category. if asking about a specific merchant, then the intent is transactional.
            4. transactional: the user wants to know about a specific transactions. this includes reccurring and subscription transactions.
            5. investing: the user has a specific question about investing and needs real-time data
            6. accounts: the user has a specific question about their accounts
            7. system: the user wants to know how to do something within the product
            
            Second, remember to keep these things in mind regarding how to resolve:
            - We have access to both historical and real-time data we can query, so we can answer questions about the user's accounts. But if we need to get that data, then content_contains_answer should be false.
            - If the user is asking for metrics, then resolution should be to query the metrics table.
            - If the user asks about a specific stock/security, always make sure data for that specific security is available, otherwise content_contains_answer should be false.

            Third, respond exclusively with in JSON format:
            {
            "user_intent": string, // The user's intent
            "intent_reasoning": string, // Why you think the user's intent is what you think it is.
            "metric_name": lowercase string, // The human name of the metric the user is asking about. Only include if intent is 'metrics'.
            "content_contains_answer": boolean, // true or false. Whether the information in the content is sufficient to resolve the issue. If intent is 'education' there's a high chance this should be true. If the intent is 'reply' this should be true.
            "justification": string, // Why the content you found is or is not sufficient to resolve the issue.
            "resolve": string, // The specific data needed to resolve the issue, succinctly. Focus on actionable, exact information.
            }
          ASSISTANT
          { role: "user", content: "User inquiry: #{message.content}" },
        ],
        temperature: 0,
        max_tokens: 500,
        response_format: { type: "json_object" }
      }
    )

    raw_response = response.dig("choices", 0, "message", "content")
    
    justification_reply = conversation.messages.new
    justification_reply.log = raw_response
    justification_reply.user = nil
    justification_reply.role = "log"
    justification_reply.hidden = true
    justification_reply.save

    JSON.parse(raw_response)
  end

  def query_openai(openai, conversation, reply)
    conversation_history = conversation.messages.where.not(content: [nil, ""]).where.not(content: "...").where.not(role: 'log').order(:created_at)

    messages = conversation_history.map do |message|
      { role: message.role, content: message.content }
    end

    total_content_length = messages.sum { |message| message[:content]&.length.to_i }

    while total_content_length > 10000
      oldest_message = messages.shift
      total_content_length -= oldest_message[:content]&.length.to_i

      if total_content_length <= 8000
        messages.unshift(oldest_message) # Put the message back if the total length is within the limit
        break
      end
    end

    message = conversation.messages.where(role: "user").order(created_at: :asc).last

    # Get the last log message from the assistant and get the 'resolve' value (log should be converted to a hash from JSON)
    last_log = conversation.messages.where(role: "log").where.not(log: nil).order(created_at: :desc).first
    last_log_json = JSON.parse(last_log.log)
    resolve_value = last_log_json["resolve"]

    text_string = ''
    
    response = openai.chat(
      parameters: {
        model: "gpt-4-1106-preview",
        messages: [
          { role: "system", content: "You are a highly intelligent certified financial advisor/teacher/mentor tasked with helping the customer make wise financial decisions based on real data. You generally respond in the Socratic style. Try to ask just the right question to help educate the user and get them thinking critically about their finances. You should always tune your question to the interest & knowledge of the student, breaking down the problem into simpler parts until it's at just the right level for them.\n\nUse only the information in the conversation to construct your response."},
          { role: "assistant", content: <<-ASSISTANT.strip_heredoc },
          Here is information about the user and their financial situation, so you understand them better:
          - Location: #{conversation.user.family.region}, #{conversation.user.family.country}
          - Age: #{conversation.user.birthday ? (Date.today.year - conversation.user.birthday.year) : "Unknown"}
          - Risk tolerance: #{conversation.user.family.risk}
          - Household: #{conversation.user.family.household}
          - Financial Goals: #{conversation.user.family.goals}
          - Investment horizon: 20 years
          - Income: $10,000 per month
          - Expenses: $9,000 per month
          - Family size: 2 adults, 2 children, 2 dogs
          - Net worth: #{conversation.user.family.net_worth}
          - Total assets: #{conversation.user.family.total_assets}
          - Total debts: #{conversation.user.family.total_debts}
          - Cash balance: #{conversation.user.family.cash_balance}
          - Investment balance: #{conversation.user.family.investment_balance}
          - Credit balance: #{conversation.user.family.credit_balance}
          - Property balance: #{conversation.user.family.property_balance}

            Follow these rules as you create your answer:
          - Keep responses very brief and to the point, unless the user asks for more details.
          - Response should be in markdown format, adding bold or italics as needed.
          - If you output a formula, wrap it in backticks.
          - Do not output any SQL, IDs or UUIDs.
          - Data should be human readable.
          - Dates should be long form.
          - If there is no data for the requested date, say there isn't enough data.
          - Don't include pleasantries.
          - Favor putting lists in tabular markdown format, especially if they're long.
          - Currencies should be output with two decimal places and a dollar sign.
          - Use full names for financial products, not abbreviations.
          - Answer truthfully and be specific.
          - If you are doing a calculation, show the formula.
          - If you don't have certain industry data, use the S&P 500 as a proxy.
          - Remember, "accounts" and "transactions" are different things.
          - If you are not absolutely sure what the user is asking, ask them to clarify. Clarity is key.
          - Unless the user explicitly asks for "pending" transactions, you should ignore all transactions where is_pending is true.

          According to the last log message, this is what is needed to answer the question: '#{resolve_value}'.

          Be sure to output what data you are using to answer the question, and why you are using it.

          ASSISTANT
          *messages
        ],
        temperature: 0,
        max_tokens: 1200,
        stream: proc do |chunks, _bytesize|
          conversation.broadcast_remove_to "conversation_area", target: "message_content_loader_#{reply.id}"

          if chunks.dig("choices")[0]["delta"].present?
            content = chunks.dig("choices", 0, "delta", "content")
            text_string += content unless content.nil?

            conversation.broadcast_append_to "conversation_area", partial: "conversations/stream", locals: { text: content }, target: "message_content_#{reply.id}"
          end

        end
      }
    )

    text_string
  end
end