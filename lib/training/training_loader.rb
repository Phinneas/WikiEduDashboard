# frozen_string_literal: true
require "#{Rails.root}/lib/training/wiki_slide_parser"

class TrainingLoader
  def initialize(content_class:, cache_key:, path_to_yaml:, trim_id_from_filename:, wiki_base_page:)
    @collection = []
    @content_class = content_class

    @cache_key = cache_key
    @path_to_yaml = path_to_yaml
    @wiki_base_page = wiki_base_page
    @trim_id_from_filename = trim_id_from_filename
  end

  def load_local_content
    load_from_yaml
    write_to_cache
  end

  def load_local_and_wiki_content
    load_from_yaml
    load_from_wiki
    write_to_cache
  end

  private

  def load_from_yaml
    Dir.glob(@path_to_yaml) do |yaml_file|
      @collection << new_from_file(yaml_file)
    end
  end

  def load_from_wiki
    wiki_source_pages.each do |wiki_page|
      content = new_from_wiki_page(wiki_page)
      unless content&.valid?
        Raven.capture_message 'Invalid wiki training content',
                              level: 'warn',
                              extra_data: { content: content }
        next
      end
      @collection << new_from_wiki_page(wiki_page)
    end
  end

  def write_to_cache
    Rails.cache.write @cache_key, @collection
  end

  def new_from_wiki_page(wiki_page)
    wikitext = WikiApi.new(MetaWiki.new).get_page_content(wiki_page)
    content = JSON.parse(wikitext)
    return unless content # Handle wiki pages that don't exist.
    if content['wiki_page']
      content.merge! training_hash_from_wiki_page(content['wiki_page'])
      content['translations'] = {}
      translated_wiki_pages(base_page: content['wiki_page']).each do |translated_page|
        language = translated_page.split('/').last
        content['translations'][language] = training_hash_from_wiki_page(translated_page)
      end
    end
    content = content.to_hashugar
    @content_class.new(content, content.slug)
  end

  def wiki_source_pages(base_page: nil)
    link_source = base_page || @wiki_base_page
    # To handle more than 500 pages linked from the source page,
    # we'll need to update this to use 'continue'.
    query_params = { prop: 'links', titles: link_source, pllimit: 500 }
    response = WikiApi.new(MetaWiki.new).query(query_params)
    begin
      response.data['pages'].values[0]['links'].map { |page| page['title'] }
    rescue
      []
    end
  end

  def translated_wiki_pages(base_page:)
    return [] unless base_page
    translations_query = { meta: 'messagegroupstats',
                           mgsgroup: "page-#{base_page}" }
    response = WikiApi.new(MetaWiki.new).query(translations_query)
    return [] unless response
    translations = []
    response.data['messagegroupstats'].each do |language|
      next if language['total'].zero?
      next if language['translated'].zero?
      translations << base_page + '/' + language['code']
    end
    return translations
  end

  def training_hash_from_wiki_page(wiki_page)
    wikitext = WikiApi.new(MetaWiki.new).get_page_content(wiki_page)
    parser = WikiSlideParser.new(wikitext)
    case @content_class.to_s
    when 'TrainingSlide'
      { title: parser.title, content: parser.content, assessment: parser.quiz }
    when 'TrainingModule'
      { name: parser.title, description: parser.content }
    end
  end

  def new_from_file(yaml_file)
    slug = File.basename(yaml_file, '.yml')
    slug.gsub!(/^[0-9]+-/, '') if @trim_id_from_filename

    content = YAML.load_file(yaml_file).to_hashugar
    @content_class.new(content, slug)
  end
end
