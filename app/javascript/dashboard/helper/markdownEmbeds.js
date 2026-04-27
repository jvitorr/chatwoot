import yaml from 'js-yaml';
import yamlSource from '../../../../config/markdown_embeds.yml?raw';

const config = yaml.load(yamlSource);

export const embeds = Object.values(config).map(({ regex, template }) => ({
  regex: new RegExp(regex),
  template,
}));
