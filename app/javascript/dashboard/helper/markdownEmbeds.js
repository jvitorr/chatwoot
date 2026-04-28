import yaml from 'js-yaml';
import yamlSource from '../../../../config/markdown_embeds.yml?raw';

const config = yaml.load(yamlSource);

// Scripts inserted via innerHTML don't execute (HTML spec), so embed templates
// that rely on <script> (e.g. github_gist, wistia) would render blank in the
// editor preview. Skip them here — they still work on the public page, where
// the markdown is parsed by the browser normally.
const isPreviewable = ({ template }) => !/<script\b/i.test(template);

export const embeds = Object.values(config)
  .filter(isPreviewable)
  .map(({ regex, template }) => ({
    regex: new RegExp(regex),
    template,
  }));
