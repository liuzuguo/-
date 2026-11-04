# encoding: UTF-8
# SketchUp Pro 2018 / Ruby 2.2+. All imported geometry is additive and undoable.
require 'sketchup.rb'
require 'json'
require 'time'
require 'digest'

module RoofPanelBridge
  extend self
  INCH_TO_M = 0.0254
  M_TO_INCH = 1.0 / INCH_TO_M
  MAX_WIDTH = 1.5
  MAX_LENGTH = 3.0
  BUILD_SCALE = 1000.0 # Avoid SketchUp small-face creation tolerance; inverse-scaled on instances.
  EPS_M = 0.00001
  ATTR = 'RoofPanelStudio'

  def finite_number(value, label)
    raise ArgumentError, "#{label} 必须是数值" unless value.is_a?(Numeric)
    n = value.to_f
    raise ArgumentError, "#{label} 必须是有限数值" unless n.finite?
    n
  end

  def sub(a, b); [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; end
  def dot(a, b); a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; end
  def cross(a, b)
    [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
  end
  def norm(a); Math.sqrt(dot(a,a)); end
  def unit(a)
    n = norm(a)
    raise ArgumentError, '存在退化的板片或共线顶点' if n < 1.0e-10
    a.map { |v| v/n }
  end
  def vector(a); Geom::Vector3d.new(a); end
  def point_m(a); Geom::Point3d.new(a.map { |v| v*M_TO_INCH }); end

  def source_info(model)
    {
      'model_name' => model.title.to_s.empty? ? '未命名模型' : model.title,
      'model_guid' => model.guid.to_s,
      'exported_at' => Time.now.iso8601,
      'scope' => 'explicit-selection',
      'units' => 'm'
    }
  end

  def entity_label(entity, fallback)
    name = entity.respond_to?(:name) ? entity.name.to_s : ''
    if name.empty? && entity.respond_to?(:definition)
      name = entity.definition.name.to_s
    end
    name.empty? ? fallback : name
  end

  def export_selected
    model = Sketchup.active_model
    selected = model.selection.to_a
    if selected.empty?
      UI.messagebox('请先明确选中屋顶顶面，或只包含屋顶顶面的群组/组件。不要选中整栋建筑。')
      return
    end
    note = "只导出当前选择的面及所选群组/组件中的全部面（包括内部隐藏面）。\n" +
      "不会自动识别或排除底面、檐口、玻璃、立面，也不会按法线方向猜测屋面。\n" +
      "请确认选择中只含需要分板的屋顶表面，且没有重叠的内外两层。继续？"
    return unless UI.messagebox(note, MB_YESNO) == IDYES
    roofs = []
    face_count = 0
    root_transform = model.edit_transform
    direct_faces = selected.select { |e| e.is_a?(Sketchup::Face) }
    sources = []
    sources << ['selection_faces', '直接选择的屋面', direct_faces, root_transform] unless direct_faces.empty?
    selected.each_with_index do |entity, i|
      next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      sources << ["roof_#{i+1}", entity_label(entity,"屋面 #{i+1}"), entities.to_a,
                  root_transform * entity.transformation]
    end
    sources.each do |id, name, entities, transformation|
      vertices, triangles, lookup = [], [], {}
      walk = nil
      walk = lambda do |items, tr, depth|
        raise ArgumentError, '组件嵌套超过 100 层，请检查选择' if depth > 100
        items.each do |entity|
          if entity.is_a?(Sketchup::Face)
            face_count += 1
            mesh = entity.mesh(0)
            mesh.polygons.each do |polygon|
              ids = polygon.map do |i|
                pos = mesh.point_at(i.abs).transform(tr)
                xyz = [pos.x.to_f*INCH_TO_M, pos.y.to_f*INCH_TO_M, pos.z.to_f*INCH_TO_M]
                key = xyz.map { |v| (v*1.0e7).round }.join(',')
                unless lookup.key?(key)
                  lookup[key] = vertices.length
                  vertices << xyz
                end
                lookup[key]
              end
              # Face#mesh returns triangulated polygons, including faces with holes.
              (1...(ids.length-1)).each do |j|
                tri = [ids[0], ids[j], ids[j+1]]
                a,b,c = tri.map { |k| vertices[k] }
                triangles << tri if norm(cross(sub(b,a),sub(c,a))) > 1.0e-12
              end
            end
          elsif entity.is_a?(Sketchup::Group)
            walk.call(entity.entities.to_a, tr*entity.transformation, depth+1)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            walk.call(entity.definition.entities.to_a, tr*entity.transformation, depth+1)
          end
        end
      end
      walk.call(entities, transformation, 0)
      roofs << {'id'=>id, 'name'=>name, 'vertices'=>vertices, 'faces'=>triangles} unless triangles.empty?
    end
    raise ArgumentError, '当前选择中没有可以导出的面' if roofs.empty?
    path = UI.savepanel('导出选中的真实屋面（单位：米）', nil, '1102e_屋面源数据.json')
    return unless path
    path += '.json' unless File.extname(path).downcase == '.json'
    payload = {'format'=>'roof-source-1', 'unit'=>'m', 'source'=>source_info(model),
               'roofs'=>roofs, 'source_face_count'=>face_count,
               'note'=>'仅为显式选择范围；屋面口径须由操作者核实，不代表自动识别或竣工尺寸。'}
    File.open(path, 'w:UTF-8') { |f| f.write(JSON.generate(payload)) }
    count = roofs.inject(0) { |sum,r| sum+r['faces'].length }
    UI.messagebox("已导出 #{roofs.length} 个选择范围、#{face_count} 个源面、#{count} 个三角面。\n单位：米；坐标为模型世界坐标。\n#{path}\n\n此源网格 JSON 与铝板分隔 JSON 是不同格式，网页须支持该源网格格式才能重新计算。")
    path
  rescue => error
    UI.messagebox("屋面导出失败：#{error.message}")
    nil
  end

  def polygon_area(points)
    # Newell area vector is exact for planar simple polygons, also concave ones.
    sum = [0.0,0.0,0.0]
    points.each_with_index do |p,i|
      q = points[(i+1)%points.length]
      c = cross(p,q)
      3.times { |k| sum[k] += c[k] }
    end
    norm(sum)*0.5
  end

  def fits_planar_envelope?(local, width, length)
    # A constrained 1.5 x 3 rectangle may fit at an angle that is not parallel
    # to any polygon edge. The min-area-box edge directions alone are incomplete.
    # Projection-span constraints change feasibility only where a vertex-pair
    # projection equals a limiting side, so test every critical angular interval.
    points=local.map { |p| [p[0],p[1]] }
    angles=[0.0]
    limits=[length+EPS_M,width+EPS_M]
    points.each_with_index do |p,i|
      ((i+1)...points.length).each do |j|
        dx=points[j][0]-p[0]; dy=points[j][1]-p[1]
        radius=Math.sqrt(dx*dx+dy*dy)
        return false if radius>Math.sqrt(limits[0]**2+limits[1]**2)+1.0e-9
        next if radius<1.0e-10
        alpha=Math.atan2(dy,dx)
        limits.each_with_index do |limit,k|
          next unless radius>limit
          center=alpha+(k==0 ? 0.0 : Math::PI/2.0)
          delta=Math.acos([[limit/radius,-1.0].max,1.0].min)
          angles << (center-delta)%Math::PI
          angles << (center+delta)%Math::PI
        end
      end
    end
    angles=angles.sort.uniq
    candidates=angles.dup
    angles.each_with_index do |a,i|
      b=i==angles.length-1 ? angles[0]+Math::PI : angles[i+1]
      candidates << ((a+b)*0.5)%Math::PI
    end
    candidates.any? do |a|
      c=Math.cos(a); si=Math.sin(a)
      xs=points.map { |q| q[0]*c+q[1]*si }
      ys=points.map { |q| -q[0]*si+q[1]*c }
      xs.max-xs.min<=limits[0]+1.0e-9 && ys.max-ys.min<=limits[1]+1.0e-9
    end
  end

  def canonical_panel(raw, index)
    raise ArgumentError, "第 #{index+1} 块板不是对象" unless raw.is_a?(Hash)
    id = raw.fetch('id', "P#{index+1}").to_s
    verts = raw['vertices']
    raise ArgumentError, "#{id} 的 vertices 应至少包含 3 个三维点" unless verts.is_a?(Array) && verts.length >= 3
    raise ArgumentError, "#{id} 顶点过多" if verts.length > 20000
    points = verts.map.with_index do |p,i|
      raise ArgumentError, "#{id} 第 #{i+1} 个点不是三维坐标" unless p.is_a?(Array) && p.length == 3
      p.map do |n|
        value = finite_number(n,"#{id} 坐标")
        raise ArgumentError, "#{id} 坐标超出合理模型范围（1000 km）" if value.abs > 1.0e6
        value
      end
    end
    faces = raw['faces'] || [(0...points.length).to_a]
    raise ArgumentError, "#{id} 没有有效 faces" unless faces.is_a?(Array) && !faces.empty?
    faces = faces.map do |f|
      raise ArgumentError, "#{id} 的面索引不正确" unless f.is_a?(Array) && f.length >= 3 &&
        f.all? { |v| v.is_a?(Integer) && v >= 0 && v < points.length } && f.uniq.length == f.length
      f
    end
    origin = points[faces[0][0]]
    axis_x = axis_z = nil
    faces.each do |f|
      a = points[f[0]]
      (1...(f.length-1)).each do |j|
        edge = sub(points[f[j]],a)
        normal = cross(edge, sub(points[f[j+1]],a))
        if norm(normal) > 1.0e-10
          axis_x, axis_z = unit(edge), unit(normal)
          break
        end
      end
      break if axis_x
    end
    raise ArgumentError, "#{id} 是退化板片" unless axis_x
    axis_y = unit(cross(axis_z,axis_x))
    local = points.map do |p|
      d=sub(p,origin)
      [dot(d,axis_x),dot(d,axis_y),dot(d,axis_z)]
    end
    area = faces.inject(0.0) do |sum,f|
      fp=f.map { |i| points[i] }
      if fp.length > 3
        normal=nil
        (1...(fp.length-1)).each do |j|
          n=cross(sub(fp[j],fp[0]),sub(fp[j+1],fp[0]))
          if norm(n)>1.0e-10; normal=unit(n); break; end
        end
        raise ArgumentError,"#{id} 存在退化多边形" unless normal
        if fp.any? { |p| dot(sub(p,fp[0]),normal).abs > 0.0001 }
          raise ArgumentError,"#{id} 的非平面多边形必须提供三角化 faces"
        end
      end
      sum+polygon_area(fp)
    end
    raise ArgumentError,"#{id} 面积为零" if area<1.0e-10
    width=finite_number(raw['width_m'],"#{id} width_m")
    length=finite_number(raw['length_m'],"#{id} length_m")
    if width <= 0 || length <= 0 || width > MAX_WIDTH+EPS_M || length > MAX_LENGTH+EPS_M
      raise ArgumentError,"#{id} 尺寸超限或无效：#{width} × #{length} m（限 1.5 × 3 m）"
    end
    reported=finite_number(raw['area_m2'],"#{id} area_m2")
    if (area-reported).abs > [0.0001,area*0.001].max
      raise ArgumentError,"#{id} 面积与几何不一致：报表 #{reported} / 几何 #{area} m²"
    end
    if area > width*length*1.001+0.00001
      raise ArgumentError,"#{id} 表面积大于标注展开包络尺寸，请检查展开口径"
    end
    planar=local.all? { |p| p[2].abs<0.0001 }
    if planar
      # Validate real intrinsic extents rather than trusting metadata alone.
      fits=false
      candidate_edges=[]
      faces.each do |f|
        f.each_with_index do |a,j|
          candidate_edges << [a,f[(j+1)%f.length]].sort
        end
      end
      candidate_edges.uniq.each do |a,b|
        edge=sub(points[b],points[a])
        next if norm(edge)<1.0e-10
        u=unit(edge); v=unit(cross(axis_z,u))
        us=points.map { |q| dot(sub(q,origin),u) }
        vs=points.map { |q| dot(sub(q,origin),v) }
        dims=[us.max-us.min,vs.max-vs.min].sort
        fits=true if dims[0] <= MAX_WIDTH+EPS_M && dims[1] <= MAX_LENGTH+EPS_M
      end
      fits ||= fits_planar_envelope?(local,MAX_WIDTH,MAX_LENGTH)
      raise ArgumentError,"#{id} 的实际几何包络超过 1.5 × 3 m" unless fits
    end
    # 0.1 micrometre rounding only absorbs floating-point transform noise;
    # component reuse never relies on rounded size/type labels alone.
    signature=JSON.generate([local.map { |p| p.map { |n| (n*1.0e7).round } },faces])
    {'id'=>id,'type_id'=>raw.fetch('type_id','未分类').to_s,
     'roof_id'=>raw.fetch('roof_id','屋面').to_s,'width_m'=>width,'length_m'=>length,
     'area_m2'=>area,'local'=>local,'origin'=>origin,'x'=>axis_x,'y'=>axis_y,'z'=>axis_z,
     'faces'=>faces,'planar'=>planar,'signature'=>Digest::SHA256.hexdigest(signature)}
  end

  def normalized_title(name)
    File.basename(name.to_s).sub(/\.skp\z/i,'').strip.downcase
  end

  def import_panels
    model=Sketchup.active_model
    if model.active_path
      UI.messagebox('请先退出群组/组件编辑状态，再导入世界坐标的铝板方案。')
      return
    end
    path=UI.openpanel('打开网页导出的铝板分隔 JSON',nil,'JSON|*.json||')
    return unless path
    raise ArgumentError,'JSON 文件过大（上限 250 MB）' if File.size(path)>250*1024*1024
    data=JSON.parse(File.open(path,'r:UTF-8') { |f| f.read }.sub(/\A\uFEFF/,''))
    raise ArgumentError,'文件必须是 roof-panels-1，单位必须为 m；不能导入屋面源网格 JSON' unless
      data.is_a?(Hash) && data['format']=='roof-panels-1' && data['unit']=='m'
    panels=data['panels']
    raise ArgumentError,'panels 必须是非空数组（最多 100000 块）' unless
      panels.is_a?(Array) && !panels.empty? && panels.length<=100000
    Sketchup.status_text="正在校验 #{panels.length} 块铝板…"
    prepared=panels.each_with_index.map { |raw,i| canonical_panel(raw,i) }
    raise ArgumentError,'铝板编号重复' unless prepared.map { |p| p['id'] }.uniq.length==prepared.length
    source=data['source'].is_a?(Hash) ? data['source'] : {}
    source_name=(source['model_name'] || source['name'] || '未标明源模型').to_s
    mismatched=normalized_title(source_name)!=normalized_title(model.title)
    mismatched ||= source['model_guid'] && source['model_guid'].to_s!=model.guid.to_s
    count=prepared.length
    area=prepared.inject(0.0) { |sum,p| sum+p['area_m2'] }
    curved=prepared.count { |p| !p['planar'] }
    warning=mismatched ? "【源模型身份未匹配】\n请确认方案确实对应本模型，坐标、比例及版本一致。\n\n" : ''
    warning+="方案来源：#{source_name}\n当前模型：#{model.title}\n" +
      "将新增 #{count} 块铝板，净表面积 #{format('%.3f',area)} m²。\n" +
      "现有几何不会被删除、移动或替换；可整体撤销。\n"
    warning+="其中 #{curved} 块为非平面网格；展开加工尺寸由方案计算，桥接未验证可展性。\n" if curved>0
    warning+="继续导入？"
    return unless UI.messagebox(warning,MB_YESNO)==IDYES
    settings=UI.inputbox(['新增方案图层名','显示抬高（mm；0 为原位，最多 20）'],
                         ['RP_屋面铝板分隔',0.0],'铝板方案导入设置')
    return unless settings
    layer_name=settings[0].to_s.strip
    raise ArgumentError,'图层名不能为空' if layer_name.empty?
    offset=Float(settings[1])/1000.0
    raise ArgumentError,'显示抬高须在 0–20 mm 之间' unless offset.finite? && offset>=0 && offset<=0.02
    operation=false
    begin
      model.start_operation('导入屋面铝板分隔',true)
      operation=true
      layer=model.layers[layer_name] || model.layers.add(layer_name)
      group=model.entities.add_group
      group.name="屋面铝板方案 #{Time.now.strftime('%Y%m%d_%H%M%S')}"
      group.layer=layer
      group.set_attribute(ATTR,'source',JSON.generate(source))
      group.set_attribute(ATTR,'panel_count',count)
      group.set_attribute(ATTR,'net_surface_area_m2',area)
      group.set_attribute(ATTR,'display_offset_m',offset)
      definitions={}
      roof_groups={}
      prepared.each_with_index do |p,i|
        definition=definitions[p['signature']]
        unless definition
          definition=model.definitions.add("RP_#{p['type_id']}_#{p['signature'][0,10]}")
          # Build large only inside the definition so short clipped mesh edges
          # can be created, then scale the instance back to exact physical size.
          # All calculations/signatures/attributes retain the original metres.
          local_points=p['local'].map do |point|
            point_m(point.map { |coordinate| coordinate*BUILD_SCALE })
          end
          p['faces'].each do |indices|
            face=definition.entities.add_face(indices.map { |v| local_points[v] })
            raise ArgumentError,"无法生成 #{p['id']} 的面；可能存在细碎边或自交" unless face
          end
          definition.entities.grep(Sketchup::Edge).each do |edge|
            if edge.faces.length==2
              angle=edge.faces[0].normal.angle_between(edge.faces[1].normal)
              if angle<=Math::PI/18.0+1.0e-9
                edge.hidden=true
                edge.soft=true
                edge.smooth=true
              end
            end
          end
          definition.set_attribute(ATTR,'shape_signature',p['signature'])
          definition.set_attribute(ATTR,'type_id',p['type_id'])
          definitions[p['signature']]=definition
        end
        roof_group=roof_groups[p['roof_id']]
        unless roof_group
          roof_group=group.entities.add_group
          roof_group.name=p['roof_id']
          roof_groups[p['roof_id']]=roof_group
        end
        origin=p['origin'].each_with_index.map { |v,k| v+p['z'][k]*offset }
        frame=Geom::Transformation.axes(point_m(origin),vector(p['x']),vector(p['y']),vector(p['z']))
        transform=frame*Geom::Transformation.scaling(1.0/BUILD_SCALE)
        instance=roof_group.entities.add_instance(definition,transform)
        instance.name=p['id']
        %w[id type_id roof_id width_m length_m area_m2 planar].each do |key|
          instance.set_attribute(ATTR,key,p[key])
        end
        Sketchup.status_text="正在导入铝板 #{i+1} / #{count}" if i%100==0
      end
      model.commit_operation
      operation=false
      model.selection.clear
      model.selection.add(group)
      UI.messagebox("导入完成：#{count} 块铝板，#{definitions.length} 个精确形状组件定义。\n" +
        "净表面积：#{format('%.3f',area)} m²。\n" +
        "显示抬高：#{format('%.1f',offset*1000)} mm（只用于模型查看）。\n" +
        "原屋面和原分隔保留。可在图层中切换新增方案，并整体撤销。\n" +
        "此步骤未保存 SKP；请核对叠合和数据后另存为新版本。")
      group
    rescue => error
      model.abort_operation if operation
      raise error
    ensure
      Sketchup.status_text=''
    end
  rescue => error
    Sketchup.status_text=''
    UI.messagebox("铝板导入失败，未保留部分导入：#{error.message}")
    nil
  end

  unless file_loaded?(__FILE__)
    menu=UI.menu('Plugins').add_submenu('屋面铝板统计桥接')
    menu.add_item('导出选中屋面 JSON…') { export_selected }
    menu.add_item('导入铝板分隔 JSON…') { import_panels }
    file_loaded(__FILE__)
  end
end
