class Captain::Llm::HelpCenterCurationSchema < RubyLLM::Schema
  CATEGORIES_DESCRIPTION = '3 to 5 high-level categories that group the chosen articles. ' \
                           'Names must be short (1-3 words) and reusable.'.freeze
  ARTICLES_DESCRIPTION = 'Up to 12 URLs from the input list that would make the best customer-support help-center articles. ' \
                         'Skip blog posts, marketing/landing pages, login, pricing, legal, careers.'.freeze
  TITLE_DESCRIPTION = 'Concise article title (max 80 chars), rewritten if the source title is too long or marketing-y.'.freeze
  CATEGORY_DESCRIPTION = 'One sentence describing what kind of articles belong in this category.'.freeze

  array :categories, description: CATEGORIES_DESCRIPTION, min_items: 1, max_items: 5 do
    object do
      string :name, description: 'Short, human-readable category name (1-3 words).', max_length: 60
      string :description, description: CATEGORY_DESCRIPTION, max_length: 200
    end
  end

  array :articles, description: ARTICLES_DESCRIPTION, min_items: 1, max_items: 12 do
    object do
      string :url, description: 'The exact URL from the input list. Do not invent URLs.'
      string :title, description: TITLE_DESCRIPTION, max_length: 80
      string :category_name, description: 'Must exactly match one of the names emitted in the categories field.', max_length: 60
    end
  end
end
